#!/usr/bin/env bash
set -euo pipefail

# Generates different load patterns against each team's inference endpoint.
# - team-alpha (disaggregated): heavy load with long prompts → high GPU utilization
# - team-beta (aggregated): light load with short prompts → moderate GPU utilization
# Runs for 10 minutes by default. Recording rules need ~5 min to produce stable cost data.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
DURATION="${LOAD_DURATION:-600}"  # 10 minutes default

echo "=== Deploying load generators ==="
echo "  team-alpha: heavy load (long prompts, continuous)"
echo "  team-beta: light load (short prompts, intermittent)"
echo "  Duration: ${DURATION}s"
echo ""

kubectl apply -f "$PROJECT_ROOT/manifests/loadgen/team-alpha-heavy.yaml"
kubectl apply -f "$PROJECT_ROOT/manifests/loadgen/team-beta-light.yaml"

echo ""
echo "=== Load generators running ==="
echo ""
echo "Wait 5 minutes for recording rules to accumulate data, then:"
echo "  ./scripts/07-validate.sh"
echo ""
echo "Or watch live:"
echo "  kubectl port-forward svc/prometheus-kube-prometheus-prometheus 9090:9090 -n monitoring &"
echo "  curl -s 'http://localhost:9090/api/v1/query?query=namespace:gpu_cost_per_hour:sum'"
echo ""
echo "To stop load early:"
echo "  kubectl delete -f $PROJECT_ROOT/manifests/loadgen/"
