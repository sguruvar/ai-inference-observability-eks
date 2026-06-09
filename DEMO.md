# Demo Script — GPU Cost Attribution Platform

**Time: 10 minutes. Run these commands in order while showing Grafana.**

---

## Setup (before demo)

```bash
# Cluster should already be running (./up.sh)
# Open these in browser tabs:
# Tab 1: Grafana Cost Dashboard    → /d/gpu-cost-attribution
# Tab 2: Grafana Disagg Dashboard  → /d/dynamo-disagg
# Tab 3: Grafana KEDA Dashboard    → /d/keda-gpu-scaling
# Tab 4: ArgoCD UI

# Set Grafana time range to "Last 15 minutes" and auto-refresh 10s
```

---

## Act 1: Show the Problem (1 min)

**Narrative:** "Two teams share a GPU cluster. Who's spending what? Are GPUs working or idle?"

```bash
# Show MIG slices — 16 isolated GPU partitions on one A100 node
kubectl get nodes -l workload=gpu -o jsonpath='{.items[0].status.allocatable.nvidia\.com/mig-3g\.20gb}'
# → 16

# Show the two teams' deployments
kubectl get dgd -n dynamo-system
# → vllm-disagg (team alpha, 2 MIG slices), vllm-agg (team beta, 1 MIG slice)
```

---

## Act 2: Generate Differentiated Load (2 min)

**Narrative:** "Team alpha runs heavy inference (long prompts, 200 tokens output). Team beta barely uses their GPU."

```bash
# Kill existing load generators
kubectl delete jobs -n dynamo-system -l app=loadgen 2>/dev/null

# Team Alpha: HEAVY sustained load (hammers the GPU)
kubectl apply -f - <<'EOF'
apiVersion: batch/v1
kind: Job
metadata:
  name: demo-heavy
  namespace: dynamo-system
  labels: {app: loadgen, team: alpha}
spec:
  parallelism: 3
  template:
    metadata:
      labels: {app: loadgen, team: alpha}
    spec:
      restartPolicy: Never
      containers:
        - name: load
          image: curlimages/curl:latest
          command: ["/bin/sh", "-c"]
          args:
            - |
              while true; do
                curl -s http://vllm-agg-frontend:8000/v1/completions \
                  -H "Content-Type: application/json" \
                  -d '{"model":"Qwen/Qwen3-0.6B","prompt":"Explain in extreme detail the entire history of GPU computing from the 1990s through 2026, covering NVIDIA CUDA architecture evolution, the transition from graphics to general purpose computing, the rise of deep learning, transformer architectures, disaggregated inference, multi-instance GPU technology, and the economic implications of GPU cloud pricing models across all major cloud providers including reserved instances, spot markets, and on-demand capacity planning strategies for enterprise AI workloads","max_tokens":500}' \
                  -o /dev/null -w "%{http_code} %{time_total}s\n" --max-time 60
              done
EOF

# Team Beta: LIGHT occasional requests (GPU mostly idle)
kubectl apply -f - <<'EOF'
apiVersion: batch/v1
kind: Job
metadata:
  name: demo-light
  namespace: dynamo-system
  labels: {app: loadgen, team: beta}
spec:
  template:
    metadata:
      labels: {app: loadgen, team: beta}
    spec:
      restartPolicy: Never
      containers:
        - name: load
          image: curlimages/curl:latest
          command: ["/bin/sh", "-c"]
          args:
            - |
              while true; do
                curl -s http://vllm-agg-frontend:8000/v1/completions \
                  -H "Content-Type: application/json" \
                  -d '{"model":"Qwen/Qwen3-0.6B","prompt":"Hi","max_tokens":5}' \
                  -o /dev/null --max-time 10
                sleep 10
              done
EOF

echo "Heavy load (3 parallel) + light load deployed"
echo "Wait 2-3 min for GPU utilization to show in dashboards"
```

---

## Act 3: Show Cost Attribution Dashboard (2 min)

**Narrative:** "Within minutes, we can see exactly who's spending what."

**Switch to Grafana Tab 1 (Cost Dashboard)**

Point out:
- **Cost per Hour table** — Team alpha: higher cost (2 MIG slices). Team beta: lower cost (1 slice)
- **Waste gauges** — Team beta's gauge should be RED (high waste — GPU allocated but barely used)
- **GPU Utilization time series** — Team alpha's line is high and sustained; beta's is flat/near-zero
- **Allocated vs Effective Cost** — The GAP between allocated (what you pay) and effective (what you use) IS the waste
- **Live AWS Pricing** — "$1.37 per MIG slice per hour — pulled from AWS Price List API in real time"

---

## Act 4: Show Disaggregated Inference Behavior (1 min)

**Switch to Grafana Tab 2 (Disagg Dashboard)**

Point out:
- **Prefill vs Decode utilization** — Prefill spikes (compute burst), decode is more sustained
- **Tensor Core Activity** — Prefill lights up tensor cores; decode doesn't
- **Memory Bandwidth** — Decode has higher DRAM activity (reading KV cache per token)
- **GPU Memory Used** — Each MIG slice holding ~11GB (model weights + KV cache)

**Say:** "This proves disaggregation works — each phase has a distinct hardware profile. You can right-size hardware per phase."

---

## Act 5: Trigger KEDA Scale-Out (2 min)

**Narrative:** "When GPU pressure exceeds threshold, KEDA adds capacity automatically."

```bash
# Lower KEDA threshold to trigger scale-out with current load
kubectl delete scaledobject -n dynamo-system prefill-scaler decode-scaler 2>/dev/null
kubectl apply -f - <<EOF
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: decode-scaler
  namespace: dynamo-system
spec:
  scaleTargetRef:
    name: $(kubectl get deployments -n dynamo-system --no-headers | grep "agg-vllmdecodeworker" | grep -v disagg | awk '{print $1}' | head -1)
  pollingInterval: 10
  cooldownPeriod: 30
  minReplicaCount: 1
  maxReplicaCount: 4
  triggers:
    - type: prometheus
      metadata:
        serverAddress: http://prometheus-kube-prometheus-prometheus.monitoring.svc.cluster.local:9090
        query: avg(DCGM_FI_DEV_FB_USED{pod=~".*agg-vllmdecodeworker.*",namespace="dynamo-system"} / (DCGM_FI_DEV_FB_USED{pod=~".*agg-vllmdecodeworker.*",namespace="dynamo-system"} + DCGM_FI_DEV_FB_FREE{pod=~".*agg-vllmdecodeworker.*",namespace="dynamo-system"}))
        threshold: "0.03"
EOF

echo "KEDA threshold set very low — will scale up within 30s"
```

**Switch to Grafana Tab 3 (KEDA Dashboard)**

Point out:
- **Decode Replicas** — watch it step from 1 → 2 (or more)
- **Scaling Signal vs Threshold** — metric crosses the line → scale event
- **Total GPU Capacity: 16** — "KEDA scales by claiming more MIG slices, not adding nodes"
- **Scale Events Timeline** — shows the exact moment KEDA acted

---

## Act 6: Test Admission Webhook (1 min)

**Narrative:** "Governance: you can't deploy GPU workloads without a team label."

```bash
# Try to deploy a GPU pod WITHOUT team label → REJECTED
kubectl run bad-pod -n dynamo-system --image=nginx \
  --overrides='{"spec":{"containers":[{"name":"c","image":"nginx","resources":{"limits":{"nvidia.com/mig-3g.20gb":"1"}}}]}}'
# → Error: admission webhook rejected: missing 'team' label

# Deploy WITH team label → ALLOWED
kubectl run good-pod -n dynamo-system --image=nginx \
  --labels="team=alpha" \
  --overrides='{"spec":{"containers":[{"name":"c","image":"nginx","resources":{"limits":{"nvidia.com/mig-3g.20gb":"1"}},"labels":{"team":"alpha"}}]}}'
# → pod/good-pod created

kubectl delete pod good-pod -n dynamo-system 2>/dev/null
```

---

## Act 7: Show ArgoCD + MCP (1 min)

**Switch to ArgoCD Tab**

Point out:
- 3 Applications: inference workloads, monitoring, autoscaling
- All synced from Git (green = healthy)
- "Teams PR their model changes → ArgoCD auto-deploys → no kubectl access needed"

**MCP Server (show terminal):**
```bash
MCP_URL="http://$(kubectl get svc gpu-mcp-server -n monitoring -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'):8080/mcp"

# Ask the platform: "What's the waste?"
curl -s -X POST "$MCP_URL" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_waste_report","arguments":{}}}' \
  | grep "data:" | head -1 | sed 's/data: //' | python3 -c "import sys,json; print(json.load(sys.stdin)['result']['content'][0]['text'])"
```

**Say:** "An AI ops agent can query cost, detect waste, and scale workers — all through MCP tools. No human intervention needed for routine right-sizing."

---

## Closing (30s)

> "This is a complete GPU inference platform: MIG for hardware isolation, disaggregated serving for efficiency, DCGM for per-pod telemetry, Prometheus recording rules for cost math, live AWS pricing, KEDA for autonomous scaling, admission webhooks for governance, ArgoCD for GitOps, Istio for traffic management, and MCP for AI-agent operability. Every dollar of GPU spend is tracked, attributed, and actionable."

---

## Cleanup

```bash
kubectl delete jobs -n dynamo-system -l app=loadgen
kubectl delete scaledobject -n dynamo-system decode-scaler 2>/dev/null
./down.sh
```
