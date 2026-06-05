#!/usr/bin/env bash
set -euo pipefail

# ONE COMMAND: destroys everything. No orphaned AWS resources.
# Usage: ./down.sh

export AWS_REGION="${AWS_REGION:-us-west-2}"
export CLUSTER_NAME="${CLUSTER_NAME:-gpu-mig-demo}"
export DYNAMO_NS="${DYNAMO_NS:-dynamo-system}"

echo "============================================"
echo " DESTROYING: $CLUSTER_NAME in $AWS_REGION"
echo "============================================"
echo ""
read -p "Are you sure? This deletes the entire cluster + all AWS resources. [y/N] " -n 1 -r
echo ""
[[ ! $REPLY =~ ^[Yy]$ ]] && echo "Aborted." && exit 0

echo ""
echo "--- [1/7] Deleting load generators + KEDA ScaledObjects ---"
kubectl delete job -n "$DYNAMO_NS" -l app=loadgen 2>/dev/null || true
kubectl delete scaledobject --all -n "$DYNAMO_NS" 2>/dev/null || true

echo "--- [2/7] Deleting DynamoGraphDeployments ---"
kubectl delete dgd --all -n "$DYNAMO_NS" 2>/dev/null || true
echo "  Waiting for GPU pods to terminate..."
sleep 15

echo "--- [3/7] Uninstalling KEDA ---"
helm uninstall keda -n keda 2>/dev/null || true
kubectl delete namespace keda --wait=false 2>/dev/null || true

echo "--- [4/7] Uninstalling Dynamo Platform ---"
helm uninstall dynamo-platform -n "$DYNAMO_NS" 2>/dev/null || true
kubectl delete pvc --all -n "$DYNAMO_NS" 2>/dev/null || true

echo "--- [5/7] Uninstalling monitoring + GPU Operator ---"
helm uninstall prometheus -n monitoring 2>/dev/null || true
kubectl delete namespace monitoring --wait=false 2>/dev/null || true
helm uninstall gpu-operator -n gpu-operator 2>/dev/null || true
kubectl delete namespace gpu-operator --wait=false 2>/dev/null || true

echo "--- [6/7] Deleting EFS + IAM ---"
EFS_ID=$(aws efs describe-file-systems --region "$AWS_REGION" \
  --query "FileSystems[?Tags[?Key=='Name'&&Value=='${CLUSTER_NAME}-models']].FileSystemId" \
  --output text 2>/dev/null || echo "")

if [ -n "$EFS_ID" ] && [ "$EFS_ID" != "None" ]; then
  echo "  Deleting EFS mount targets..."
  aws efs describe-mount-targets --file-system-id "$EFS_ID" --region "$AWS_REGION" \
    --query 'MountTargets[].MountTargetId' --output text 2>/dev/null | tr '\t' '\n' | while read MT; do
    [ -n "$MT" ] && aws efs delete-mount-target --mount-target-id "$MT" --region "$AWS_REGION" 2>/dev/null || true
  done
  echo "  Waiting for mount targets to delete (30s)..."
  sleep 30
  aws efs delete-file-system --file-system-id "$EFS_ID" --region "$AWS_REGION" 2>/dev/null || true
  echo "  EFS $EFS_ID deleted"
fi

ROLE_NAME="${CLUSTER_NAME}-pricing-exporter"
ASSOC_ID=$(aws eks list-pod-identity-associations --cluster-name "$CLUSTER_NAME" --region "$AWS_REGION" \
  --query "associations[?serviceAccount=='gpu-pricing-exporter'].associationId" --output text 2>/dev/null || echo "")
[ -n "$ASSOC_ID" ] && aws eks delete-pod-identity-association \
  --cluster-name "$CLUSTER_NAME" --association-id "$ASSOC_ID" --region "$AWS_REGION" 2>/dev/null || true
aws iam delete-role-policy --role-name "$ROLE_NAME" --policy-name "pricing-get-products" 2>/dev/null || true
aws iam delete-role --role-name "$ROLE_NAME" 2>/dev/null || true
echo "  IAM role $ROLE_NAME deleted"

echo "--- [7/7] Deleting EKS cluster (~5 min) ---"
eksctl delete cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" --force

echo ""
echo "============================================"
echo " ALL RESOURCES DESTROYED"
echo "============================================"
echo ""
echo " Verify:"
echo "   eksctl get cluster --region $AWS_REGION"
echo "   aws efs describe-file-systems --region $AWS_REGION --query 'FileSystems[?Tags[?Key==\`Name\`&&contains(Value,\`$CLUSTER_NAME\`)]].FileSystemId'"
