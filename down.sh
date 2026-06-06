#!/usr/bin/env bash
set -euo pipefail

# ONE COMMAND: destroys everything. No orphaned AWS resources.
# Usage: ./down.sh

export AWS_REGION="${AWS_REGION:-us-east-2}"
export CLUSTER_NAME="${CLUSTER_NAME:-gpu-mig-demo}"
export DYNAMO_NS="${DYNAMO_NS:-dynamo-system}"

echo "============================================"
echo " DESTROYING: $CLUSTER_NAME in $AWS_REGION"
echo "============================================"
echo ""
read -p "Are you sure? This deletes EVERYTHING. [y/N] " -n 1 -r
echo ""
[[ ! $REPLY =~ ^[Yy]$ ]] && echo "Aborted." && exit 0

echo ""
echo "--- [1/8] Deleting load generators + KEDA ---"
kubectl delete job -n "$DYNAMO_NS" -l app=loadgen 2>/dev/null || true
kubectl delete scaledobject --all -n "$DYNAMO_NS" 2>/dev/null || true
helm uninstall keda -n keda 2>/dev/null || true

echo "--- [2/8] Deleting webhooks ---"
kubectl delete validatingwebhookconfiguration gpu-team-label-validator 2>/dev/null || true
kubectl delete mutatingwebhookconfiguration gpu-toleration-injector 2>/dev/null || true
helm uninstall cert-manager -n cert-manager 2>/dev/null || true
kubectl delete namespace gpu-webhook --wait=false 2>/dev/null || true
kubectl delete namespace cert-manager --wait=false 2>/dev/null || true

echo "--- [3/8] Deleting DynamoGraphDeployments ---"
kubectl delete dgd --all -n "$DYNAMO_NS" 2>/dev/null || true
echo "  Waiting for GPU pods to terminate..."
sleep 15

echo "--- [4/8] Uninstalling Dynamo Platform ---"
helm uninstall dynamo-platform -n "$DYNAMO_NS" 2>/dev/null || true
kubectl delete pvc --all -n "$DYNAMO_NS" 2>/dev/null || true

echo "--- [5/8] Uninstalling monitoring + GPU Operator ---"
helm uninstall prometheus -n monitoring 2>/dev/null || true
kubectl delete namespace monitoring --wait=false 2>/dev/null || true
helm uninstall gpu-operator -n gpu-operator 2>/dev/null || true
kubectl delete namespace gpu-operator --wait=false 2>/dev/null || true

echo "--- [6/8] Deleting EFS ---"
EFS_ID=$(aws efs describe-file-systems --region "$AWS_REGION" \
  --query "FileSystems[?Tags[?Key=='Name'&&Value=='${CLUSTER_NAME}-models']].FileSystemId" \
  --output text 2>/dev/null || echo "")

if [ -n "$EFS_ID" ] && [ "$EFS_ID" != "None" ]; then
  echo "  Deleting EFS mount targets..."
  aws efs describe-mount-targets --file-system-id "$EFS_ID" --region "$AWS_REGION" \
    --query 'MountTargets[].MountTargetId' --output text 2>/dev/null | tr '\t' '\n' | while read MT; do
    [ -n "$MT" ] && aws efs delete-mount-target --mount-target-id "$MT" --region "$AWS_REGION" 2>/dev/null || true
  done
  sleep 30
  aws efs delete-file-system --file-system-id "$EFS_ID" --region "$AWS_REGION" 2>/dev/null || true
  echo "  EFS $EFS_ID deleted"
fi

echo "--- [7/8] Deleting IAM + ECR ---"
ROLE_NAME="${CLUSTER_NAME}-pricing-exporter"
ASSOC_ID=$(aws eks list-pod-identity-associations --cluster-name "$CLUSTER_NAME" --region "$AWS_REGION" \
  --query "associations[?serviceAccount=='gpu-pricing-exporter'].associationId" --output text 2>/dev/null || echo "")
[ -n "$ASSOC_ID" ] && aws eks delete-pod-identity-association \
  --cluster-name "$CLUSTER_NAME" --association-id "$ASSOC_ID" --region "$AWS_REGION" 2>/dev/null || true
aws iam delete-role-policy --role-name "$ROLE_NAME" --policy-name "pricing-get-products" 2>/dev/null || true
aws iam delete-role --role-name "$ROLE_NAME" 2>/dev/null || true

# Delete ECR repos
aws ecr delete-repository --repository-name "${CLUSTER_NAME}-webhook" \
  --region "$AWS_REGION" --force 2>/dev/null || true
aws ecr delete-repository --repository-name "${CLUSTER_NAME}-mcp-server" \
  --region "$AWS_REGION" --force 2>/dev/null || true

echo "--- [8/8] Deleting EKS cluster (~5 min) ---"
eksctl delete cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" --force

echo ""
echo "============================================"
echo " ALL RESOURCES DESTROYED"
echo "============================================"
