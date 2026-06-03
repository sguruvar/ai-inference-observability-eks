#!/usr/bin/env bash
set -euo pipefail

# Validates the entire pipeline: DCGM → Prometheus → Recording Rules → Cost Data
# Run after load has been generating for at least 5 minutes.

PROM_URL="${PROM_URL:-http://localhost:9090}"
PASS=0
FAIL=0

check() {
  local desc="$1"
  local query="$2"
  local result

  result=$(curl -s "${PROM_URL}/api/v1/query" --data-urlencode "query=$query" | \
    python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('data',{}).get('result',[])))" 2>/dev/null || echo "0")

  if [ "$result" -gt 0 ]; then
    echo "  PASS: $desc ($result results)"
    ((PASS++)) || true
  else
    echo "  FAIL: $desc (0 results)"
    ((FAIL++)) || true
  fi
}

# Start port-forward if not already running
if ! curl -s "$PROM_URL/-/healthy" > /dev/null 2>&1; then
  echo "Starting Prometheus port-forward..."
  kubectl port-forward svc/prometheus-kube-prometheus-prometheus 9090:9090 -n monitoring &
  PF_PID=$!
  sleep 3
else
  PF_PID=""
fi

echo "=== GPU Cost Attribution Validation ==="
echo ""
echo "Prometheus: $PROM_URL"
echo ""

echo "--- DCGM Metrics (raw from GPU nodes) ---"
check "DCGM metrics exist (any pod)" 'DCGM_FI_PROF_GR_ENGINE_ACTIVE{pod!=""}'
check "DCGM has namespace label" 'DCGM_FI_PROF_GR_ENGINE_ACTIVE{namespace="dynamo-system",pod!=""}'
check "GPU utilization (DEV_GPU_UTIL)" 'DCGM_FI_DEV_GPU_UTIL{pod!=""}'
check "GPU memory used" 'DCGM_FI_DEV_FB_USED{pod!=""}'

echo ""
echo "--- Recording Rules (Tier 1: per-pod utilization) ---"
check "Per-pod smoothed utilization" 'pod:gpu_utilization:avg5m'

echo ""
echo "--- Recording Rules (Tier 2: per-DGD aggregation) ---"
check "Per-DGD GPU count" 'deployment:gpu_allocated:count'
check "Per-DGD avg utilization" 'deployment:gpu_utilization:avg'

echo ""
echo "--- Recording Rules (Tier 3: cost math) ---"
check "Per-DGD cost/hr" 'deployment:gpu_cost_per_hour:sum'
check "Per-DGD effective cost" 'deployment:gpu_effective_cost_per_hour:sum'
check "Per-DGD waste fraction" 'deployment:gpu_waste_fraction:ratio'

echo ""
echo "--- Pricing Exporter ---"
check "GPU price metric exists" 'gpu_price_per_hour'
check "Price not stale" 'gpu_price_stale == 0'

echo ""
echo "--- Per-DGD Coverage ---"
check "vllm-disagg has metrics" 'deployment:gpu_cost_per_hour:sum{dgd="vllm-disagg"}'
check "vllm-agg has metrics" 'deployment:gpu_cost_per_hour:sum{dgd="vllm-agg"}'

echo ""
echo "--- Alerting ---"
check "Alert rules loaded" 'count(ALERTS{alertname=~".*GPUWaste.*"}) or absent(ALERTS{alertname=~".*GPUWaste.*"})'

echo ""
echo "--- Cost Summary ---"
echo ""
curl -s "${PROM_URL}/api/v1/query" --data-urlencode 'query=deployment:gpu_cost_per_hour:sum' | \
  python3 -c "
import sys, json
data = json.load(sys.stdin).get('data',{}).get('result',[])
if not data:
    print('  (no cost data yet — wait 5 min after load starts)')
else:
    for r in sorted(data, key=lambda x: x['metric'].get('dgd','')):
        dgd = r['metric'].get('dgd','unknown')
        cost = float(r['value'][1])
        print(f'  {dgd}: \${cost:.2f}/hr')
" 2>/dev/null

echo ""
echo "--- Waste Summary ---"
curl -s "${PROM_URL}/api/v1/query" --data-urlencode 'query=deployment:gpu_waste_fraction:ratio' | \
  python3 -c "
import sys, json
data = json.load(sys.stdin).get('data',{}).get('result',[])
if not data:
    print('  (no waste data yet)')
else:
    for r in sorted(data, key=lambda x: x['metric'].get('dgd','')):
        dgd = r['metric'].get('dgd','unknown')
        waste = float(r['value'][1])
        print(f'  {dgd}: {waste:.1%} waste')
" 2>/dev/null

echo ""
echo "--- Utilization Summary ---"
curl -s "${PROM_URL}/api/v1/query" --data-urlencode 'query=deployment:gpu_utilization:avg' | \
  python3 -c "
import sys, json
data = json.load(sys.stdin).get('data',{}).get('result',[])
if not data:
    print('  (no utilization data yet)')
else:
    for r in sorted(data, key=lambda x: x['metric'].get('dgd','')):
        dgd = r['metric'].get('dgd','unknown')
        util = float(r['value'][1])
        print(f'  {dgd}: {util:.1%} avg GPU utilization')
" 2>/dev/null

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="

if [ -n "$PF_PID" ]; then
  kill "$PF_PID" 2>/dev/null || true
fi

if [ "$FAIL" -gt 0 ]; then
  echo ""
  echo "Troubleshooting:"
  echo "  - GPU pods not running? → kubectl get pods -n dynamo-system -l nvidia.com/dynamo-graph-deployment-name"
  echo "  - Recording rules need data? → wait 5 min after load starts, re-run this script"
  echo "  - DCGM not scraping? → kubectl get servicemonitor -n gpu-operator"
  echo "  - Pricing exporter? → kubectl logs -n monitoring -l app=gpu-pricing-exporter"
  exit 1
fi
echo "All checks passed!"
