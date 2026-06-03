#!/usr/bin/env bash
set -euo pipefail

# Installs the full observability stack:
# - kube-prometheus-stack (Prometheus + Grafana + AlertManager)
# - GPU recording rules (3-tier cost math)
# - GPU alerting rules (waste detection)
# - Custom pricing exporter (AWS Price List API → $/GPU/hr)
# - Grafana dashboards (cost attribution + Dynamo disaggregated)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
REGION="${AWS_REGION:-us-east-1}"
CLUSTER_NAME="${CLUSTER_NAME:-dynamo-cost-demo}"
DYNAMO_NS="${DYNAMO_NS:-dynamo-system}"

echo "=== Step 1/6: Installing kube-prometheus-stack ==="
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
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

echo ""
echo "=== Step 2/6: Applying GPU recording rules ==="
kubectl apply -f "$PROJECT_ROOT/manifests/monitoring/gpu-recording-rules.yaml"

echo ""
echo "=== Step 3/6: Applying GPU alerting rules ==="
kubectl apply -f "$PROJECT_ROOT/manifests/monitoring/gpu-alerting-rules.yaml"

echo ""
echo "=== Step 4/6: Deploying GPU Pricing Exporter ==="
ACCOUNT_ID=$(aws sts get-caller-identity --query 'Account' --output text)
ROLE_NAME="${CLUSTER_NAME}-pricing-exporter"

# Create IAM role for EKS Pod Identity
TRUST_POLICY='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"pods.eks.amazonaws.com"},"Action":["sts:AssumeRole","sts:TagSession"]}]}'

aws iam create-role --role-name "$ROLE_NAME" \
  --assume-role-policy-document "$TRUST_POLICY" 2>/dev/null || \
  aws iam update-assume-role-policy --role-name "$ROLE_NAME" \
  --policy-document "$TRUST_POLICY"

aws iam put-role-policy --role-name "$ROLE_NAME" \
  --policy-name "pricing-get-products" \
  --policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":"pricing:GetProducts","Resource":"*"}]}'

ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"
echo "  IAM role: $ROLE_ARN"

# Create Pod Identity association
aws eks create-pod-identity-association \
  --cluster-name "$CLUSTER_NAME" \
  --namespace monitoring \
  --service-account gpu-pricing-exporter \
  --role-arn "$ROLE_ARN" \
  --region "$REGION" 2>/dev/null || true

# Deploy pricing exporter manifests (remove IRSA annotation placeholder)
sed "s|ROLE_ARN_PLACEHOLDER|$ROLE_ARN|g" "$PROJECT_ROOT/manifests/pricing-exporter/deployment.yaml" | kubectl apply -f -
kubectl apply -f "$PROJECT_ROOT/manifests/pricing-exporter/service.yaml"
kubectl apply -f "$PROJECT_ROOT/manifests/pricing-exporter/servicemonitor.yaml"

echo ""
echo "=== Step 5/6: Deploying Grafana dashboards ==="
kubectl apply -f "$PROJECT_ROOT/manifests/dashboards/gpu-cost-dashboard.yaml"
kubectl apply -f "$PROJECT_ROOT/manifests/dashboards/dynamo-disagg-dashboard.yaml"

echo ""
echo "=== Step 6/6: Updating Dynamo Operator with Prometheus endpoint ==="
# This lets Dynamo emit its own metrics (frontend request counts, prefill/decode latency)
DYNAMO_VERSION=$(helm list -n "$DYNAMO_NS" -o json | python3 -c "import sys,json; charts=json.load(sys.stdin); print(next((c['chart'].replace('dynamo-platform-','') for c in charts if c['name']=='dynamo-platform'),'1.0.0'))" 2>/dev/null || echo "1.0.0")

# Only upgrade if dynamo is installed
if helm list -n "$DYNAMO_NS" | grep -q dynamo-platform; then
  kubectl delete secret grove-webhook-server-cert -n "$DYNAMO_NS" --ignore-not-found=true
  helm upgrade dynamo-platform "nvidia-dynamo/dynamo-platform" \
    --version "$DYNAMO_VERSION" \
    --namespace "$DYNAMO_NS" \
    --reuse-values \
    --set prometheusEndpoint=http://prometheus-kube-prometheus-prometheus.monitoring.svc.cluster.local:9090 2>/dev/null || \
    echo "  (Dynamo Prometheus endpoint update skipped — may not be available in this chart version)"
fi

echo ""
echo "=== Monitoring stack installed ==="
echo ""
echo "  Prometheus: kubectl port-forward svc/prometheus-kube-prometheus-prometheus 9090:9090 -n monitoring"
echo "  Grafana:    kubectl port-forward svc/prometheus-grafana 3000:80 -n monitoring"
echo "              Login: admin / prom-operator"
echo ""
echo "Recording rules will produce data once GPU workloads are running (after Step 5)."
echo ""
echo "Next: ./scripts/05-deploy-inference.sh"
