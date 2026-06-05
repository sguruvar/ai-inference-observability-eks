#!/usr/bin/env bash
set -euo pipefail

# ONE COMMAND: creates full stack from zero.
#
# Components:
#   - EKS cluster (Auto Mode for system, Managed Node Group for GPU/MIG)
#   - GPU Operator with MIG Manager (configures A100 MIG slices)
#   - NVIDIA Dynamo (disaggregated inference: prefill + decode on MIG slices)
#   - Prometheus + Grafana (exposed via LoadBalancer — no port-forward needed)
#   - KEDA (autoscales prefill/decode independently)
#   - Admission Webhooks (validates team label, mutates GPU tolerations)
#   - Load generators (heavy vs light traffic patterns)
#
# Usage:
#   export HF_TOKEN="hf_xxx" && ./up.sh
#
# Cost: ~$35/hr (p4d.24xlarge on-demand + system nodes)
# Time: ~20 min to fully operational
# Destroy: ./down.sh

export AWS_REGION="${AWS_REGION:-us-west-2}"
export CLUSTER_NAME="${CLUSTER_NAME:-gpu-mig-demo}"
export DYNAMO_NS="${DYNAMO_NS:-dynamo-system}"
HF_TOKEN="${HF_TOKEN:?ERROR: Set HF_TOKEN (https://huggingface.co/settings/tokens)}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "============================================"
echo " GPU Cost Attribution + MIG + KEDA + Webhooks"
echo " Region:  $AWS_REGION"
echo " Cluster: $CLUSTER_NAME"
echo " GPU:     p4d.24xlarge (8× A100 40GB, MIG)"
echo " Cost:    ~\$35/hr on-demand"
echo "============================================"
echo ""

# ─── Step 1: EKS Cluster with Managed GPU Node Group ──────────────────────────
echo "=== [1/8] Creating EKS cluster + p4d GPU node group (~15 min) ==="

# Clean up any leftover CF stacks from failed previous runs
EXISTING_STACK=$(aws cloudformation describe-stacks --stack-name "eksctl-${CLUSTER_NAME}-cluster" \
  --region "$AWS_REGION" --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo "NONE")
if [ "$EXISTING_STACK" != "NONE" ]; then
  echo "  Found existing stack (status: $EXISTING_STACK). Cleaning up..."
  if [ "$EXISTING_STACK" = "DELETE_FAILED" ]; then
    # Delete EFS mount targets first (they hold VPC security groups)
    OLD_EFS=$(aws efs describe-file-systems --region "$AWS_REGION" \
      --query "FileSystems[?Tags[?Key=='Name'&&Value=='${CLUSTER_NAME}-models']].FileSystemId" --output text 2>/dev/null || echo "")
    if [ -n "$OLD_EFS" ] && [ "$OLD_EFS" != "None" ]; then
      echo "  Cleaning up leftover EFS $OLD_EFS..."
      aws efs describe-mount-targets --file-system-id "$OLD_EFS" --region "$AWS_REGION" \
        --query 'MountTargets[].MountTargetId' --output text 2>/dev/null | tr '\t' '\n' | while read MT; do
        [ -n "$MT" ] && aws efs delete-mount-target --mount-target-id "$MT" --region "$AWS_REGION" 2>/dev/null || true
      done
      sleep 30
      aws efs delete-file-system --file-system-id "$OLD_EFS" --region "$AWS_REGION" 2>/dev/null || true
    fi
    # Now delete orphaned security groups
    VPC_ID=$(aws cloudformation describe-stack-resources --stack-name "eksctl-${CLUSTER_NAME}-cluster" \
      --region "$AWS_REGION" --query "StackResources[?LogicalResourceId=='VPC'].PhysicalResourceId" --output text 2>/dev/null || echo "")
    if [ -n "$VPC_ID" ]; then
      aws ec2 describe-security-groups --region "$AWS_REGION" --filters "Name=vpc-id,Values=$VPC_ID" \
        --query "SecurityGroups[?GroupName!='default'].GroupId" --output text 2>/dev/null | tr '\t' '\n' | while read SG; do
        [ -n "$SG" ] && aws ec2 delete-security-group --group-id "$SG" --region "$AWS_REGION" 2>/dev/null || true
      done
    fi
    aws cloudformation delete-stack --stack-name "eksctl-${CLUSTER_NAME}-cluster" --region "$AWS_REGION" 2>/dev/null || true
  fi
  echo "  Waiting for old stack to finish deleting..."
  aws cloudformation wait stack-delete-complete --stack-name "eksctl-${CLUSTER_NAME}-cluster" --region "$AWS_REGION" 2>/dev/null || true
fi

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

# Managed nodegroups need VPC CNI + kube-proxy (Auto Mode handles these for its own nodes but not managed NGs)
echo "  Installing VPC CNI + kube-proxy addons for managed nodegroup..."
aws eks create-addon --cluster-name "$CLUSTER_NAME" --addon-name vpc-cni --region "$AWS_REGION" 2>/dev/null || true
aws eks create-addon --cluster-name "$CLUSTER_NAME" --addon-name kube-proxy --region "$AWS_REGION" 2>/dev/null || true
aws eks wait addon-active --cluster-name "$CLUSTER_NAME" --addon-name vpc-cni --region "$AWS_REGION" 2>/dev/null || true

echo "  Adding GPU managed node group (p4d.24xlarge)..."
cat <<EOF > /tmp/eksctl-gpu-ng.yaml
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig

metadata:
  name: ${CLUSTER_NAME}
  region: ${AWS_REGION}

managedNodeGroups:
  - name: gpu-mig
    instanceType: p4d.24xlarge
    privateNetworking: true
    desiredCapacity: 1
    minSize: 0
    maxSize: 2
    labels:
      workload: gpu
    taints:
      - key: nvidia.com/gpu
        value: "true"
        effect: NoSchedule
    iam:
      withAddonPolicies:
        ebs: true
EOF

eksctl create nodegroup -f /tmp/eksctl-gpu-ng.yaml

# Fix NAT routing: managed nodegroups may land in public subnet without public IP
# Find the GPU node's subnet and ensure it routes through NAT gateway
echo "  Fixing NAT route for GPU subnet..."
sleep 10  # Wait for node to register
GPU_NODE_IP=$(kubectl get nodes -l workload=gpu -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || echo "")
if [ -n "$GPU_NODE_IP" ]; then
  GPU_SUBNET=$(aws ec2 describe-instances --region "$AWS_REGION" \
    --filters "Name=private-ip-address,Values=$GPU_NODE_IP" \
    --query 'Reservations[].Instances[].SubnetId' --output text 2>/dev/null)
  VPC_ID=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" \
    --query 'cluster.resourcesVpcConfig.vpcId' --output text)
  NAT_GW=$(aws ec2 describe-nat-gateways --region "$AWS_REGION" \
    --filter "Name=vpc-id,Values=$VPC_ID" "Name=state,Values=available" \
    --query 'NatGateways[0].NatGatewayId' --output text 2>/dev/null)
  GPU_RT=$(aws ec2 describe-route-tables --region "$AWS_REGION" \
    --filters "Name=association.subnet-id,Values=$GPU_SUBNET" \
    --query 'RouteTables[0].RouteTableId' --output text 2>/dev/null)
  if [ -n "$NAT_GW" ] && [ "$NAT_GW" != "None" ] && [ -n "$GPU_RT" ]; then
    aws ec2 replace-route --route-table-id "$GPU_RT" --destination-cidr-block 0.0.0.0/0 \
      --nat-gateway-id "$NAT_GW" --region "$AWS_REGION" 2>/dev/null || true
    echo "  GPU subnet routed through NAT gateway"
  fi
fi

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
# ─── Step 2: GPU Operator + MIG ───────────────────────────────────────────────
echo "=== [2/8] Installing GPU Operator + MIG Manager (~5 min) ==="

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
  --set-string 'dcgmExporter.env[0].name=DCGM_EXPORTER_KUBERNETES' \
  --set-string 'dcgmExporter.env[0].value=true' \
  --set dcgmExporter.serviceMonitor.enabled=true \
  --set dcgmExporter.serviceMonitor.honorLabels=true \
  --set dcgmExporter.serviceMonitor.additionalLabels.release=prometheus \
  --set migManager.enabled=true \
  --set-string 'migManager.env[0].name=WITH_REBOOT' \
  --set-string 'migManager.env[0].value=true' \
  --set mig.strategy=mixed \
  --set nodeStatusExporter.enabled=true \
  --set node-feature-discovery.enabled=true \
  --wait --timeout=600s

echo ""
echo "  Waiting for GPU node to be Ready before triggering MIG..."
for i in $(seq 1 60); do
  GPU_NODE=$(kubectl get nodes -l workload=gpu --no-headers 2>/dev/null | grep " Ready " | awk '{print $1}')
  if [ -n "$GPU_NODE" ]; then
    echo "  GPU node ready: $GPU_NODE"
    break
  fi
  [ "$((i % 10))" -eq 0 ] && echo "  Waiting for GPU node... (attempt $i/60)"
  sleep 10
done

# Increase ASG health check grace period BEFORE triggering MIG reboot
echo "  Setting ASG health check grace period to 900s (survive MIG reboot)..."
ASG_NAME=$(aws autoscaling describe-auto-scaling-groups --region "$AWS_REGION" \
  --query "AutoScalingGroups[?contains(AutoScalingGroupName,'gpu-mig')].AutoScalingGroupName" --output text 2>/dev/null)
[ -n "$ASG_NAME" ] && aws autoscaling update-auto-scaling-group \
  --auto-scaling-group-name "$ASG_NAME" --health-check-grace-period 900 --region "$AWS_REGION" 2>/dev/null

# NOW apply MIG label — this triggers the MIG Manager to configure GPUs
echo "  Applying MIG label (triggers GPU reconfig + reboot)..."
kubectl label nodes -l workload=gpu nvidia.com/mig.config=all-3g.20gb --overwrite 2>/dev/null

echo "  Waiting for MIG configuration on GPU node..."
echo "  (MIG Manager reads nvidia.com/mig.config label → configures GPUs → node reboots)"
for i in $(seq 1 90); do
  MIG_STATE=$(kubectl get nodes -l workload=gpu -o jsonpath='{.items[0].metadata.labels.nvidia\.com/mig\.config\.state}' 2>/dev/null || echo "")
  if [ "$MIG_STATE" = "success" ]; then
    MIG_SLICES=$(kubectl get nodes -l workload=gpu -o jsonpath='{.items[0].status.allocatable.nvidia\.com/mig-3g\.20gb}' 2>/dev/null || echo "0")
    echo "  MIG configured: $MIG_SLICES slices available (state: success)"
    break
  fi
  if [ "$((i % 10))" -eq 0 ]; then
    echo "  Waiting for MIG... state=$MIG_STATE (attempt $i/90)"
  fi
  sleep 10
done

# Post-MIG cleanup: remove stale unreachable taint from reboot
echo "  Removing stale taints from MIG reboot..."
kubectl taint nodes -l workload=gpu node.kubernetes.io/unreachable- 2>/dev/null || true
kubectl taint nodes -l workload=gpu node.kubernetes.io/not-ready- 2>/dev/null || true

# Restart device plugin to pick up MIG device inventory
echo "  Restarting device plugin for MIG slice allocation..."
kubectl rollout restart daemonset/nvidia-device-plugin-daemonset -n gpu-operator 2>/dev/null || true
kubectl rollout status daemonset/nvidia-device-plugin-daemonset -n gpu-operator --timeout=120s 2>/dev/null || true

# Wait for node to re-advertise MIG slices after device plugin restart
for i in $(seq 1 30); do
  MIG_SLICES=$(kubectl get nodes -l workload=gpu -o jsonpath='{.items[0].status.allocatable.nvidia\.com/mig-3g\.20gb}' 2>/dev/null || echo "0")
  if [ "$MIG_SLICES" != "0" ] && [ -n "$MIG_SLICES" ]; then
    echo "  Device plugin ready: $MIG_SLICES MIG slices allocatable"
    break
  fi
  sleep 5
done

echo ""
# ─── Step 3: Dynamo Platform ──────────────────────────────────────────────────
echo "=== [3/8] Installing Dynamo Platform (~3 min) ==="

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

echo "  EFS: $EFS_ID"
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
# ─── Step 4: Monitoring (Prometheus + Grafana via LoadBalancer) ────────────────
echo "=== [4/8] Installing Monitoring (Grafana exposed via LoadBalancer) (~3 min) ==="

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
  --set grafana.service.type=LoadBalancer \
  --set-string grafana.service.annotations."service\.beta\.kubernetes\.io/aws-load-balancer-scheme"=internet-facing \
  --set-string grafana.service.annotations."service\.beta\.kubernetes\.io/aws-load-balancer-type"=external \
  --set-string grafana.service.annotations."service\.beta\.kubernetes\.io/aws-load-balancer-nlb-target-type"=ip \
  --set alertmanager.enabled=true \
  --wait --timeout=300s

# Apply recording rules, alerting rules, dashboards
kubectl apply -f "$SCRIPT_DIR/manifests/monitoring/gpu-recording-rules.yaml"
kubectl apply -f "$SCRIPT_DIR/manifests/monitoring/gpu-alerting-rules.yaml"
kubectl apply -f "$SCRIPT_DIR/manifests/dashboards/"

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

sed "s|ROLE_ARN_PLACEHOLDER|$ROLE_ARN|g" "$SCRIPT_DIR/manifests/pricing-exporter/deployment.yaml" | kubectl apply -f -
kubectl apply -f "$SCRIPT_DIR/manifests/pricing-exporter/service.yaml"
kubectl apply -f "$SCRIPT_DIR/manifests/pricing-exporter/servicemonitor.yaml"

echo ""
# ─── Step 5: KEDA ─────────────────────────────────────────────────────────────
echo "=== [5/8] Installing KEDA (~1 min) ==="

helm repo add kedacore https://kedacore.github.io/charts 2>/dev/null || true
helm repo update kedacore

helm upgrade --install keda kedacore/keda \
  -n keda --create-namespace \
  --wait --timeout=120s

echo ""
# ─── Step 6: Admission Webhooks ───────────────────────────────────────────────
echo "=== [6/8] Deploying Admission Webhooks (~2 min) ==="

# Install cert-manager (needed for webhook TLS)
helm repo add jetstack https://charts.jetstack.io 2>/dev/null || true
helm repo update jetstack
helm upgrade --install cert-manager jetstack/cert-manager \
  -n cert-manager --create-namespace \
  --set crds.enabled=true \
  --wait --timeout=120s

# Build and push webhook image to ECR
ACCOUNT_ID=$(aws sts get-caller-identity --query 'Account' --output text)
ECR_REPO="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${CLUSTER_NAME}-webhook"

aws ecr create-repository --repository-name "${CLUSTER_NAME}-webhook" \
  --region "$AWS_REGION" 2>/dev/null || true
aws ecr get-login-password --region "$AWS_REGION" | \
  docker login --username AWS --password-stdin "${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

docker build -t "$ECR_REPO:latest" "$SCRIPT_DIR/webhook/"
docker push "$ECR_REPO:latest"

# Deploy webhook
sed "s|GPU_WEBHOOK_IMAGE_PLACEHOLDER|$ECR_REPO:latest|g" \
  "$SCRIPT_DIR/manifests/webhook/deployment.yaml" | kubectl apply -f -

# Wait for namespace to exist, then create cert
kubectl wait --for=condition=Ready pod -l app.kubernetes.io/instance=cert-manager \
  -n cert-manager --timeout=60s 2>/dev/null || true
sleep 5
kubectl apply -f "$SCRIPT_DIR/manifests/webhook/certificate.yaml"

# Wait for cert to be ready
echo "  Waiting for TLS certificate..."
for i in $(seq 1 30); do
  CERT_READY=$(kubectl get certificate gpu-webhook-cert -n gpu-webhook \
    -o jsonpath='{.status.conditions[0].status}' 2>/dev/null || echo "False")
  [ "$CERT_READY" = "True" ] && break
  sleep 5
done

# Restart webhook to pick up cert
kubectl rollout restart deployment/gpu-webhook -n gpu-webhook 2>/dev/null || true
kubectl rollout status deployment/gpu-webhook -n gpu-webhook --timeout=60s 2>/dev/null || true

# Register webhooks with API server
kubectl apply -f "$SCRIPT_DIR/manifests/webhook/webhook-config.yaml"

echo "  Webhooks registered:"
echo "    - ValidatingWebhook: rejects GPU pods without 'team' label"
echo "    - MutatingWebhook: injects GPU toleration + cost annotation"

echo ""
# ─── Step 7: Deploy Inference (DGDs) ──────────────────────────────────────────
echo "=== [7/8] Deploying Inference (DGDs on MIG slices) ==="

kubectl apply -f "$SCRIPT_DIR/manifests/inference/team-alpha-disagg.yaml"
kubectl apply -f "$SCRIPT_DIR/manifests/inference/team-beta-agg.yaml"

echo "  Waiting for inference pods..."
for i in $(seq 1 90); do
  RUNNING=$(kubectl get pods -n "$DYNAMO_NS" -l nvidia.com/dynamo-graph-deployment-name \
    --no-headers 2>/dev/null | { grep "Running" || true; } | wc -l | tr -d ' ')
  if [ "$RUNNING" -ge 3 ]; then
    echo "  Inference pods running ($RUNNING pods)"
    break
  fi
  if [ "$((i % 15))" -eq 0 ]; then
    echo "  Waiting... $RUNNING pods running (attempt $i/90)"
  fi
  sleep 10
done

echo ""
# ─── Step 8: KEDA ScaledObjects + Load Generators ─────────────────────────────
echo "=== [8/8] Deploying KEDA ScaledObjects + Load Generators ==="

kubectl apply -f "$SCRIPT_DIR/manifests/keda/"
kubectl apply -f "$SCRIPT_DIR/manifests/loadgen/"

echo ""
# ─── Done ─────────────────────────────────────────────────────────────────────
GRAFANA_URL=$(kubectl get svc prometheus-grafana -n monitoring \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "pending")

echo "============================================"
echo " CLUSTER READY"
echo "============================================"
echo ""
echo " Grafana:    http://${GRAFANA_URL}"
echo "             Login: admin / prom-operator"
echo "             (LoadBalancer may take 2 min to provision)"
echo ""
echo " Dashboards:"
echo "   - GPU Cost Attribution: /d/gpu-cost-attribution"
echo "   - Disaggregated Inference: /d/dynamo-disagg"
echo "   - KEDA GPU Autoscaling: /d/keda-gpu-scaling"
echo ""
echo " MIG Slices: kubectl get nodes -l workload=gpu -o jsonpath='{.items[*].status.allocatable}' | python3 -m json.tool | grep mig"
echo ""
echo " Test webhook:"
echo "   kubectl run bad-pod -n dynamo-system --image=nginx --overrides='{\"spec\":{\"containers\":[{\"name\":\"c\",\"image\":\"nginx\",\"resources\":{\"limits\":{\"nvidia.com/gpu\":\"1\"}}}]}}'"
echo "   → should be REJECTED (missing team label)"
echo ""
echo " Destroy: ./down.sh"
echo " Cost: ~\$35/hr — DESTROY WHEN DONE"
echo "============================================"
