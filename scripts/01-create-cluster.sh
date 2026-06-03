#!/usr/bin/env bash
set -euo pipefail

# Creates an EKS Auto Mode cluster with GPU NodePool.
# EKS Auto Mode uses Karpenter under the hood — GPU nodes appear when pods request GPUs.

REGION="${AWS_REGION:-us-east-1}"
CLUSTER_NAME="${CLUSTER_NAME:-dynamo-cost-demo}"

echo "=== Step 1/4: Discovering availability zones ==="
EKS_CP_AZS=$(aws ec2 describe-availability-zones \
  --region "${REGION}" \
  --filters "Name=opt-in-status,Values=opt-in-not-required" \
  --query "AvailabilityZones[].ZoneName" \
  --output text | tr '\t' '\n' | head -3 | awk '{print "  - " $1}')

echo "Using AZs:"
echo "$EKS_CP_AZS"

echo ""
echo "=== Step 2/4: Creating EKS Auto Mode cluster ==="
echo "This takes ~12-15 minutes..."

cat <<EOF > /tmp/eksctl-dynamo.yaml
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig

metadata:
  name: ${CLUSTER_NAME}
  region: ${REGION}

availabilityZones:
${EKS_CP_AZS}

autoModeConfig:
  enabled: true

addons:
  - name: aws-efs-csi-driver
    version: latest
    useDefaultPodIdentityAssociations: true
EOF

eksctl create cluster -f /tmp/eksctl-dynamo.yaml

echo ""
echo "=== Step 3/4: Creating GPU NodePool ==="
# Targets g6e (L40S) — widely available on spot, good for Dynamo demo
# Also includes p5 for full MIG mode if you have reserved capacity
kubectl apply -f - <<EOF
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: gpu
spec:
  disruption:
    budgets:
      - nodes: 10%
    consolidateAfter: 300s
    consolidationPolicy: WhenEmptyOrUnderutilized
  template:
    spec:
      nodeClassRef:
        group: eks.amazonaws.com
        kind: NodeClass
        name: default
      requirements:
        - key: karpenter.sh/capacity-type
          operator: In
          values:
            - spot
            - on-demand
        - key: eks.amazonaws.com/instance-family
          operator: In
          values:
            - g6e
            - g5
            - p5
      taints:
        - effect: NoSchedule
          key: nvidia.com/gpu
          value: "true"
EOF

echo ""
echo "=== Step 4/4: Creating default StorageClass ==="
# Needed for NATS and etcd PVCs in Dynamo
kubectl apply -f - <<EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: auto-ebs-sc
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
allowedTopologies:
- matchLabelExpressions:
  - key: eks.amazonaws.com/compute-type
    values:
    - auto
provisioner: ebs.csi.eks.amazonaws.com
volumeBindingMode: WaitForFirstConsumer
parameters:
  type: gp3
  encrypted: "true"
EOF

echo ""
echo "=== Cluster created ==="
echo "  Name:   $CLUSTER_NAME"
echo "  Region: $REGION"
echo "  Mode:   Auto Mode (Karpenter manages nodes)"
echo ""
echo "GPU nodes will appear when workloads request nvidia.com/gpu resources."
echo ""
echo "Next: ./scripts/02-install-gpu-operator.sh"
