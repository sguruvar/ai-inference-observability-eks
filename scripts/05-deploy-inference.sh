#!/usr/bin/env bash
set -euo pipefail

# Deploys two Dynamo inference graphs (DGDs) in dynamo-system namespace:
# - vllm-disagg (team alpha): disaggregated (prefill + decode workers) — Dynamo's KV-cache transfer
# - vllm-agg (team beta): aggregated (single worker) — baseline comparison
# Both use Qwen3-0.6B (small, fast to download, fits on single L40S GPU)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
DYNAMO_NS="${DYNAMO_NS:-dynamo-system}"

echo "=== Step 1/2: Deploying vllm-disagg (team alpha — disaggregated) ==="
echo ""
echo "  Architecture:"
echo "    Frontend → PrefillWorker (GPU, compute-bound) → [NIXL KV transfer] → DecodeWorker (GPU, memory-bound)"
echo ""
echo "  Why separate prefill and decode?"
echo "    - Prefill processes entire prompt at once (tensor core heavy, high SM utilization)"
echo "    - Decode generates one token at a time (memory bandwidth heavy, low SM utilization)"
echo "    - Separating them lets you scale each independently"
echo ""

kubectl apply -f "$PROJECT_ROOT/manifests/inference/team-alpha-disagg.yaml"

echo ""
echo "=== Step 2/2: Deploying vllm-agg (team beta — aggregated) ==="
echo ""
echo "  Architecture:"
echo "    Frontend → VllmWorker (GPU) — handles both phases in one pod"
echo ""

kubectl apply -f "$PROJECT_ROOT/manifests/inference/team-beta-agg.yaml"

echo ""
echo "=== Waiting for GPU nodes + pods ==="
echo "Karpenter will provision g6e.2xlarge instances (2-5 min for first GPU node)..."
echo "Workers will download Qwen3-0.6B (~1.2GB) on first start."
echo ""

for i in $(seq 1 60); do
  RUNNING=$(kubectl get pods -n "$DYNAMO_NS" -l nvidia.com/dynamo-graph-deployment-name --no-headers 2>/dev/null | { grep "Running" || true; } | wc -l | tr -d ' ')
  if [ "$RUNNING" -ge 3 ]; then
    echo "  All inference pods running ($RUNNING pods)"
    break
  fi
  if [ "$((i % 10))" -eq 0 ]; then
    echo "  Waiting... $RUNNING/3+ pods running (attempt $i/60)"
    kubectl get pods -n "$DYNAMO_NS" -l nvidia.com/dynamo-graph-deployment-name --no-headers 2>/dev/null | head -5
  fi
  sleep 10
done

echo ""
echo "=== Inference deployed ==="
echo ""
kubectl get pods -n "$DYNAMO_NS" -l nvidia.com/dynamo-graph-deployment-name
echo ""
echo "Test disaggregated serving:"
echo "  kubectl port-forward svc/vllm-disagg-frontend 8000:8000 -n $DYNAMO_NS"
echo '  curl localhost:8000/v1/chat/completions -H "Content-Type: application/json" \'
echo '    -d '\''{"model":"Qwen/Qwen3-0.6B","messages":[{"role":"user","content":"What is GPU MIG?"}],"max_tokens":50}'\'''
echo ""
echo "Next: ./scripts/06-generate-load.sh"
