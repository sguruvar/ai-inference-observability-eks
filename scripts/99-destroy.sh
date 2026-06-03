#!/usr/bin/env bash
set -euo pipefail

# Tears down everything in reverse order. Leaves no orphaned AWS resources.

REGION="${AWS_REGION:-us-east-1}"
CLUSTER_NAME="${CLUSTER_NAME:-dynamo-cost-demo}"
DYNAMO_NS="${DYNAMO_NS:-dynamo-system}"

echo "=== Destroying: GPU Cost Attribution + Dynamo Demo ==="
echo "  Cluster: $CLUSTER_NAME"
echo "  Region: $REGION"
echo ""
read -p "Are you sure? This deletes the entire cluster. [y/N] " -n 1 -r
echo ""
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
  echo "Aborted."
  exit 0
fi

echo ""
echo "--- Step 1/7: Deleting load generators ---"
kubectl delete job -n "$DYNAMO_NS" -l app=loadgen 2>/dev/null || true

echo "--- Step 2/7: Deleting DynamoGraphDeployments ---"
kubectl delete dgd --all -n "$DYNAMO_NS" 2>/dev/null || true
echo "  Waiting for GPU pods to terminate..."
sleep 15

echo "--- Step 3/7: Uninstalling Dynamo Platform ---"
helm uninstall dynamo-platform -n "$DYNAMO_NS" 2>/dev/null || true
kubectl delete pvc --all -n "$DYNAMO_NS" 2>/dev/null || true

echo "--- Step 4/7: Uninstalling monitoring stack ---"
helm uninstall prometheus -n monitoring 2>/dev/null || true
kubectl delete namespace monitoring --wait=false 2>/dev/null || true

echo "--- Step 5/7: Uninstalling GPU Operator ---"
helm uninstall gpu-operator -n gpu-operator 2>/dev/null || true
kubectl delete namespace gpu-operator --wait=false 2>/dev/null || true

echo "--- Step 6/7: Deleting EFS filesystem ---"
EFS_ID=$(aws efs describe-file-systems --region "$REGION" \
  --query "FileSystems[?Tags[?Key=='Name'&&Value=='${CLUSTER_NAME}-models']].FileSystemId" \
  --output text 2>/dev/null || echo "")

if [ -n "$EFS_ID" ] && [ "$EFS_ID" != "None" ] && [ "$EFS_ID" != "" ]; then
  echo "  Deleting EFS mount targets..."
  MOUNT_TARGETS=$(aws efs describe-mount-targets --file-system-id "$EFS_ID" --region "$REGION" \
    --query 'MountTargets[].MountTargetId' --output text 2>/dev/null || echo "")
  for MT in $MOUNT_TARGETS; do
    aws efs delete-mount-target --mount-target-id "$MT" --region "$REGION" 2>/dev/null || true
  done
  echo "  Waiting for mount targets to delete (30s)..."
  sleep 30
  aws efs delete-file-system --file-system-id "$EFS_ID" --region "$REGION" 2>/dev/null || true
  echo "  EFS $EFS_ID deleted"
else
  echo "  No EFS filesystem found"
fi

echo "--- Step 7/7: Deleting IAM role + Pod Identity + EKS cluster ---"
ROLE_NAME="${CLUSTER_NAME}-pricing-exporter"
ROLE_ARN="arn:aws:iam::$(aws sts get-caller-identity --query Account --output text):role/${ROLE_NAME}"

# Delete pod identity association
ASSOC_ID=$(aws eks list-pod-identity-associations --cluster-name "$CLUSTER_NAME" --region "$REGION" \
  --query "associations[?serviceAccount=='gpu-pricing-exporter'].associationId" --output text 2>/dev/null || echo "")
if [ -n "$ASSOC_ID" ]; then
  aws eks delete-pod-identity-association --cluster-name "$CLUSTER_NAME" --association-id "$ASSOC_ID" --region "$REGION" 2>/dev/null || true
fi

aws iam delete-role-policy --role-name "$ROLE_NAME" --policy-name "pricing-get-products" 2>/dev/null || true
aws iam delete-role --role-name "$ROLE_NAME" 2>/dev/null || true
echo "  IAM role $ROLE_NAME deleted"

echo ""
echo "Deleting EKS cluster (takes ~5 min)..."
eksctl delete cluster --name "$CLUSTER_NAME" --region "$REGION" --force

echo ""
echo "=== All resources destroyed ==="
echo ""
echo "Verify no orphans:"
echo "  aws efs describe-file-systems --region $REGION"
echo "  aws iam get-role --role-name $ROLE_NAME 2>&1"
echo "  eksctl get cluster --region $REGION"
