#!/usr/bin/env bash
set -euo pipefail

# ONE COMMAND: creates cluster, installs everything, deploys inference, starts load.
# Usage: export HF_TOKEN="hf_xxx" && ./up.sh
# Cost: ~$35/hr on-demand (p4d.24xlarge + system nodes)
# Time: ~20 min to fully operational

export AWS_REGION="${AWS_REGION:-us-west-2}"
export CLUSTER_NAME="${CLUSTER_NAME:-gpu-mig-demo}"
export DYNAMO_NS="${DYNAMO_NS:-dynamo-system}"
HF_TOKEN="${HF_TOKEN:?ERROR: Set HF_TOKEN (https://huggingface.co/settings/tokens)}"

echo "============================================"
echo " GPU Cost Attribution + MIG + KEDA Demo"
echo " Region:  $AWS_REGION"
echo " Cluster: $CLUSTER_NAME"
echo " Cost:    ~\$35/hr (p4d.24xlarge on-demand)"
echo "============================================"
echo ""

# ─── Step 1: EKS Cluster ───────────────────────────────────────────────────────
echo "=== [1/7] Creating EKS Auto Mode cluster (~12 min) ==="

EKS_CP_AZS=$(aws ec2 describe-availability-zones \
  --region "${AWS_REGION}" \
  --filters "Name=opt-in-status,Values=opt-in-not-required" \
  --query "AvailabilityZones[].ZoneName" \
  --output text | tr '\t' '\n' | head -3 | awk '{print "  - " $1}')

cat <<EOF > /tmp/eksctl-cluster.yaml
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig
metadata:
  name: ${CLUSTER_NAME}
  region: ${AWS_REGION}
availabilityZones:
${EKS_CP_AZS}
autoModeConfig:
  enabled: true
addons:
  - name: aws-efs-csi-driver
    version: latest
    useDefaultPodIdentityAssociations: true
EOF

eksctl create cluster -f /tmp/eksctl-cluster.yaml

# GPU NodePool — targets p4d (A100, MIG-capable) on-demand
kubectl apply -f - <<EOF
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: gpu-mig
spec:
  disruption:
    budgets:
      - nodes: 10%
    consolidateAfter: 600s
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
            - on-demand
        - key: eks.amazonaws.com/instance-family
          operator: In
          values:
            - p4d
            - p5
      taints:
        - effect: NoSchedule
          key: nvidia.com/gpu
          value: "true"
EOF

# Default StorageClass for NATS/etcd PVCs
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
echo "=== [2/7] Installing GPU Operator + MIG (~3 min) ==="

helm repo add nvidia https://helm.ngc.nvidia.com/nvidia 2>/dev/null || true
helm repo update nvidia

kubectl create namespace gpu-operator --dry-run=client -o yaml | kubectl apply -f -

helm upgrade --install gpu-operator nvidia/gpu-operator \
  --namespace gpu-operator \
  --set operator.defaultRuntime=containerd \
  --set driver.enabled=true \
  --set toolkit.enabled=true \
  --set devicePlugin.enabled=true \
  --set dcgmExporter.enabled=true \
  --set-string dcgmExporter.env[0].name=DCGM_EXPORTER_KUBERNETES \
  --set-string dcgmExporter.env[0].value="true" \
  --set dcgmExporter.serviceMonitor.enabled=true \
  --set dcgmExporter.serviceMonitor.honorLabels=true \
  --set dcgmExporter.serviceMonitor.additionalLabels.release=prometheus \
  --set migManager.enabled=true \
  --set-string migManager.env[0].name=WITH_REBOOT \
  --set-string migManager.env[0].value="true" \
  --set mig.strategy=mixed \
  --set nodeStatusExporter.enabled=true \
  --set node-feature-discovery.enabled=true \
  --wait --timeout=600s

echo ""
echo "=== [3/7] Installing Dynamo Platform (~3 min) ==="

helm repo add nvidia-dynamo https://helm.ngc.nvidia.com/nvidia/ai-dynamo 2>/dev/null || true
helm repo update nvidia-dynamo

kubectl create namespace "$DYNAMO_NS" --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret generic hf-token-secret \
  --from-literal=HF_TOKEN="$HF_TOKEN" \
  -n "$DYNAMO_NS" --dry-run=client -o yaml | kubectl apply -f -

# EFS for shared model storage
VPC_ID=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" \
  --query 'cluster.resourcesVpcConfig.vpcId' --output text)
SUBNET_IDS=$(aws ec2 describe-subnets --region "$AWS_REGION" \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=map-public-ip-on-launch,Values=false" \
  --query 'Subnets[].SubnetId' --output text)
CLUSTER_SG=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" \
  --query 'cluster.resourcesVpcConfig.clusterSecurityGroupId' --output text)

EFS_ID=$(aws efs create-file-system --region "$AWS_REGION" \
  --performance-mode generalPurpose --throughput-mode bursting --encrypted \
  --tags Key=Name,Value="${CLUSTER_NAME}-models" \
  --query 'FileSystemId' --output text)

echo "  EFS: $EFS_ID — waiting for available..."
for i in $(seq 1 30); do
  STATE=$(aws efs describe-file-systems --file-system-id "$EFS_ID" --region "$AWS_REGION" \
    --query 'FileSystems[0].LifeCycleState' --output text)
  [ "$STATE" = "available" ] && break
  sleep 5
done

for SUBNET in $(echo "$SUBNET_IDS" | tr '\t' '\n'); do
  aws efs create-mount-target --file-system-id "$EFS_ID" --subnet-id "$SUBNET" \
    --security-groups "$CLUSTER_SG" --region "$AWS_REGION" 2>/dev/null || true
done

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

helm upgrade --install dynamo-platform nvidia-dynamo/dynamo-platform \
  --version 1.1.1 --namespace "$DYNAMO_NS" --wait --timeout=300s

echo ""
echo "=== [4/7] Installing Monitoring (Prometheus + Grafana) (~2 min) ==="

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
helm repo update prometheus-community

helm upgrade --install prometheus prometheus-community/kube-prometheus-stack \
  -n monitoring --create-namespace \
  --set prometheus.prometheusSpec.podMonitorSelectorNilUsesHelmValues=false \
  --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
  --set prometheus.prometheusSpec.ruleSelectorNilUsesHelmValues=false \
  --set-json 'prometheus.prometheusSpec.podMonitorNamespaceSelector={}' \
  --set-json 'prometheus.prometheusSpec.serviceMonitorNamespaceSelector={}' \
  --set prometheus.prometheusSpec.retention=7d \
  --set grafana.enabled=true \
  --set grafana.adminPassword=prom-operator \
  --set grafana.sidecar.dashboards.enabled=true \
  --set grafana.sidecar.dashboards.label=grafana_dashboard \
  --set alertmanager.enabled=true \
  --wait --timeout=300s

# Recording rules, alerting rules, dashboards
kubectl apply -f manifests/monitoring/gpu-recording-rules.yaml
kubectl apply -f manifests/monitoring/gpu-alerting-rules.yaml
kubectl apply -f manifests/dashboards/

# Pricing exporter with Pod Identity
ACCOUNT_ID=$(aws sts get-caller-identity --query 'Account' --output text)
ROLE_NAME="${CLUSTER_NAME}-pricing-exporter"
TRUST_POLICY='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"pods.eks.amazonaws.com"},"Action":["sts:AssumeRole","sts:TagSession"]}]}'

aws iam create-role --role-name "$ROLE_NAME" \
  --assume-role-policy-document "$TRUST_POLICY" 2>/dev/null || \
  aws iam update-assume-role-policy --role-name "$ROLE_NAME" --policy-document "$TRUST_POLICY"
aws iam put-role-policy --role-name "$ROLE_NAME" --policy-name "pricing-get-products" \
  --policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":"pricing:GetProducts","Resource":"*"}]}'

ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"
aws eks create-pod-identity-association --cluster-name "$CLUSTER_NAME" \
  --namespace monitoring --service-account gpu-pricing-exporter \
  --role-arn "$ROLE_ARN" --region "$AWS_REGION" 2>/dev/null || true

sed "s|ROLE_ARN_PLACEHOLDER|$ROLE_ARN|g" manifests/pricing-exporter/deployment.yaml | kubectl apply -f -
kubectl apply -f manifests/pricing-exporter/service.yaml
kubectl apply -f manifests/pricing-exporter/servicemonitor.yaml

echo ""
echo "=== [5/7] Installing KEDA (~1 min) ==="

helm repo add kedacore https://kedacore.github.io/charts 2>/dev/null || true
helm repo update kedacore

helm upgrade --install keda kedacore/keda \
  -n keda --create-namespace \
  --wait --timeout=120s

echo ""
echo "=== [6/7] Deploying Inference (DGDs) ==="

kubectl apply -f manifests/inference/team-alpha-disagg.yaml
kubectl apply -f manifests/inference/team-beta-agg.yaml

echo ""
echo "  Waiting for GPU node + MIG configuration..."
echo "  (p4d.24xlarge takes 3-5 min to provision + configure MIG)"
echo ""

for i in $(seq 1 90); do
  RUNNING=$(kubectl get pods -n "$DYNAMO_NS" -l nvidia.com/dynamo-graph-deployment-name --no-headers 2>/dev/null | { grep "Running" || true; } | wc -l | tr -d ' ')
  if [ "$RUNNING" -ge 3 ]; then
    echo "  Inference pods running ($RUNNING pods)"
    break
  fi
  if [ "$((i % 15))" -eq 0 ]; then
    echo "  Waiting... $RUNNING pods running (attempt $i/90)"
    kubectl get nodes --no-headers 2>/dev/null | awk '{print "    node: "$1, $2, $5}'
  fi
  sleep 10
done

echo ""
echo "=== [7/7] Deploying KEDA ScaledObjects + Load Generators ==="

kubectl apply -f manifests/keda/
kubectl apply -f manifests/loadgen/

echo ""
echo "============================================"
echo " CLUSTER READY"
echo "============================================"
echo ""
echo " Grafana:  kubectl port-forward svc/prometheus-grafana 3000:80 -n monitoring"
echo "           http://localhost:3000 (admin / prom-operator)"
echo ""
echo " Prometheus: kubectl port-forward svc/prometheus-kube-prometheus-prometheus 9090:9090 -n monitoring"
echo ""
echo " Validate:  ./scripts/07-validate.sh"
echo " Destroy:   ./down.sh"
echo ""
echo " Cost: ~\$35/hr — DESTROY WHEN DONE"
echo "============================================"
