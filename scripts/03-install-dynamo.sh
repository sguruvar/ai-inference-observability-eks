#!/usr/bin/env bash
set -euo pipefail

# Installs NVIDIA Dynamo Platform: Operator + NATS + etcd + CRDs.
# Also sets up model storage (EFS) and HuggingFace token.

REGION="${AWS_REGION:-us-east-1}"
CLUSTER_NAME="${CLUSTER_NAME:-dynamo-cost-demo}"
DYNAMO_NS="${DYNAMO_NS:-dynamo-system}"
DYNAMO_VERSION="1.1.1"
HF_TOKEN="${HF_TOKEN:?ERROR: Set HF_TOKEN environment variable (get from https://huggingface.co/settings/tokens)}"

echo "=== Step 1/5: Adding Dynamo Helm repo ==="
helm repo add nvidia-dynamo https://helm.ngc.nvidia.com/nvidia/ai-dynamo
helm repo update nvidia-dynamo

echo ""
echo "=== Step 2/5: Creating namespace + HuggingFace secret ==="
kubectl create namespace "$DYNAMO_NS" --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic hf-token-secret \
  --from-literal=HF_TOKEN="$HF_TOKEN" \
  -n "$DYNAMO_NS" \
  --dry-run=client -o yaml | kubectl apply -f -

echo ""
echo "=== Step 3/5: Setting up EFS for shared model storage ==="
# Create EFS filesystem
VPC_ID=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" \
  --query 'cluster.resourcesVpcConfig.vpcId' --output text)

SUBNET_IDS=$(aws ec2 describe-subnets --region "$REGION" \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=map-public-ip-on-launch,Values=false" \
  --query 'Subnets[].SubnetId' --output text)

# Get cluster security group
CLUSTER_SG=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" \
  --query 'cluster.resourcesVpcConfig.clusterSecurityGroupId' --output text)

# Create EFS
EFS_ID=$(aws efs create-file-system --region "$REGION" \
  --performance-mode generalPurpose \
  --throughput-mode bursting \
  --encrypted \
  --tags Key=Name,Value="${CLUSTER_NAME}-models" \
  --query 'FileSystemId' --output text)

echo "  EFS created: $EFS_ID"
echo "  Waiting for EFS to become available..."
for i in $(seq 1 30); do
  STATE=$(aws efs describe-file-systems --file-system-id "$EFS_ID" --region "$REGION" \
    --query 'FileSystems[0].LifeCycleState' --output text)
  if [ "$STATE" = "available" ]; then
    echo "  EFS is available"
    break
  fi
  sleep 5
done

# Create mount targets in each subnet
for SUBNET in $SUBNET_IDS; do
  aws efs create-mount-target \
    --file-system-id "$EFS_ID" \
    --subnet-id "$SUBNET" \
    --security-groups "$CLUSTER_SG" \
    --region "$REGION" 2>/dev/null || true
done

echo "  Mount targets created in all private subnets"

# Create StorageClass + PV + PVC for models
kubectl apply -f - <<EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: efs-sc
provisioner: efs.csi.eks.amazonaws.com
parameters:
  provisioningMode: efs-ap
  fileSystemId: ${EFS_ID}
  directoryPerms: "700"
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: dynamo-models-pv
spec:
  capacity:
    storage: 100Gi
  volumeMode: Filesystem
  accessModes:
    - ReadWriteMany
  persistentVolumeReclaimPolicy: Retain
  storageClassName: efs-sc
  csi:
    driver: efs.csi.eks.amazonaws.com
    volumeHandle: ${EFS_ID}
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: dynamo-models-pvc
  namespace: ${DYNAMO_NS}
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: efs-sc
  resources:
    requests:
      storage: 100Gi
  volumeName: dynamo-models-pv
EOF

echo ""
echo "=== Step 4/5: Installing Dynamo Platform ==="
echo "Components: Dynamo Operator + NATS (message bus) + etcd (service discovery)"
echo ""

helm upgrade --install dynamo-platform nvidia-dynamo/dynamo-platform \
  --version "$DYNAMO_VERSION" \
  --namespace "$DYNAMO_NS" \
  --wait --timeout=300s

echo ""
echo "=== Step 5/5: Verifying installation ==="
echo ""
kubectl get pods -n "$DYNAMO_NS"
echo ""
kubectl get crds | grep dynamo

echo ""
echo "=== Dynamo Platform installed ==="
echo ""
echo "  Namespace: $DYNAMO_NS"
echo "  Components: Operator + NATS + etcd"
echo "  Model storage: EFS ($EFS_ID)"
echo "  HF token: configured"
echo ""
echo "Next: ./scripts/04-install-monitoring.sh"
