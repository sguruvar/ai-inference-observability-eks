# Disaggregated LLM Inference Cost Attribution on EKS with NVIDIA Dynamo

This walkthrough deploys NVIDIA Dynamo's disaggregated vLLM serving on EKS, instruments it with DCGM + Prometheus, and builds per-namespace GPU cost attribution with recording rules and alerts.

**Time:** ~2 hours end-to-end (20 min setup, 10 min deploy, 5 min load, rest is observing + teardown)
**Cost:** ~$5 total on g6e.2xlarge spot instances

---

## What You'll Learn

1. How Dynamo splits LLM inference into prefill workers (compute-heavy) and decode workers (memory-heavy)
2. How DCGM Exporter reports per-pod GPU utilization via the kubelet PodResources API
3. How Prometheus recording rules build 3-tier cost math (utilization → slices → dollars)
4. How a custom pricing exporter makes cost dynamic via the AWS Price List API
5. How AlertManager fires when a namespace wastes GPU capacity

---

## Prerequisites

```bash
# Verify tools are installed
aws --version          # AWS CLI v2
eksctl version         # eksctl
kubectl version --client  # kubectl
helm version           # Helm 3

# Verify AWS credentials
aws sts get-caller-identity

# Set environment variables (used by all scripts)
export AWS_REGION="us-east-1"
export CLUSTER_NAME="dynamo-cost-demo"
export DYNAMO_NS="dynamo-system"
export HF_TOKEN="hf_xxxxxxxxxxxxxxxxxxxx"  # Get from https://huggingface.co/settings/tokens
```

---

## Step 1: Create EKS Cluster

This creates an EKS Auto Mode cluster. Auto Mode handles node provisioning via Karpenter — you don't manage node groups manually.

```bash
./scripts/01-create-cluster.sh
```

**What happens:**
- Creates EKS Auto Mode cluster with OIDC provider
- Creates a GPU NodePool targeting g6e instances (L40S, easy to get on spot)
- Creates a default StorageClass for NATS/etcd persistent volumes
- Takes ~12-15 minutes

**Verify:**
```bash
kubectl get nodes        # Should show system nodes (GPU nodes appear when workloads request GPUs)
kubectl get nodepool gpu # Should show Ready=True
```

---

## Step 2: Install GPU Operator

The GPU Operator manages the full NVIDIA stack: driver, device plugin, DCGM exporter, MIG manager.

```bash
./scripts/02-install-gpu-operator.sh
```

**What happens:**
- Installs NVIDIA GPU Operator with DCGM ServiceMonitor enabled
- Configures DCGM to use Kubernetes integration mode (PodResources API → pod/namespace labels on metrics)
- Sets `honorLabels: true` so Prometheus keeps DCGM's native pod labels
- Creates custom DCGM metrics ConfigMap (subset of fields to avoid scrape timeout)

**Key config that enables pod-to-GPU correlation:**
```yaml
dcgmExporter:
  env:
    - name: DCGM_EXPORTER_KUBERNETES
      value: "true"         # ← This makes DCGM call kubelet PodResources API
  serviceMonitor:
    enabled: true
    honorLabels: true       # ← This preserves workload pod/namespace labels
    additionalLabels:
      release: prometheus   # ← This lets Prometheus discover the ServiceMonitor
```

**Verify:**
```bash
kubectl get pods -n gpu-operator    # Wait for all pods Running (takes 2-3 min after GPU node appears)
```

---

## Step 3: Install Dynamo Platform

Dynamo needs: NATS (message bus), etcd (service discovery), and the Dynamo Operator (manages DynamoGraphDeployment CRDs).

```bash
./scripts/03-install-dynamo.sh
```

**What happens:**
- Fetches Dynamo Platform Helm chart from NGC
- Installs in `dynamo-system` namespace
- Creates HuggingFace token secret (for model download)
- Creates EFS storage class + PV for shared model weights

**Verify:**
```bash
kubectl get pods -n $DYNAMO_NS
# Should see:
#   dynamo-platform-dynamo-operator-controller-manager-xxx   1/1 Running
#   dynamo-platform-nats-0                                   2/2 Running

kubectl get crds | grep dynamo
# Should see dynamographdeployments.nvidia.com etc.
```

---

## Step 4: Install Monitoring Stack

Prometheus + Grafana + AlertManager + recording rules + pricing exporter + dashboards.

```bash
./scripts/04-install-monitoring.sh
```

**What happens:**
1. Installs kube-prometheus-stack (Prometheus + Grafana + AlertManager)
2. Applies GPU recording rules (3-tier cost math)
3. Applies GPU alerting rules (waste > 40% for 10 min)
4. Deploys custom pricing exporter (calls AWS Price List API, exposes $/GPU/hr)
5. Deploys Grafana dashboard ConfigMaps (auto-imported by sidecar)
6. Updates Dynamo Operator with Prometheus endpoint (for Dynamo's own metrics)

**The 3-tier recording rules (the cost math):**
```
Tier 1: namespace_pod:gpu_utilization:avg5m
        = avg_over_time(DCGM_FI_PROF_GR_ENGINE_ACTIVE{pod!=""}[5m])
        → Per-pod smoothed GPU utilization

Tier 2: namespace:gpu_allocated:count
        = count(DCGM_FI_PROF_GR_ENGINE_ACTIVE{pod!=""}) by (namespace)
        → How many GPUs each namespace is using

Tier 3: namespace:gpu_cost_per_hour:sum
        = namespace:gpu_allocated:count × gpu_price_per_hour
        → Dollars per hour per namespace
```

**Verify:**
```bash
kubectl get pods -n monitoring         # All Running
kubectl get prometheusrule -n monitoring  # gpu-recording-rules, gpu-alerting-rules
```

---

## Step 5: Deploy Disaggregated Inference

This deploys two DynamoGraphDeployments in separate namespaces to simulate multi-tenant cost attribution.

```bash
./scripts/05-deploy-inference.sh
```

**What happens:**
- Downloads model weights to shared EFS
- Deploys `team-alpha` namespace: disaggregated vLLM (1 prefill + 1 decode worker)
- Deploys `team-beta` namespace: aggregated vLLM (1 combined worker)
- Each worker gets 1 GPU (g6e.2xlarge = 1× L40S per instance)

**Architecture of disaggregated serving:**
```
User request → Frontend (no GPU)
                  ↓
              PrefillWorker (GPU, compute-bound)
              - Processes full input prompt
              - Generates KV cache
              - High SM utilization, short duration
                  ↓ NIXL KV-cache transfer (TCP)
              DecodeWorker (GPU, memory-bound)
              - Auto-regressive token generation
              - Reads KV cache from memory
              - Low SM utilization, long duration
                  ↓
              Tokens streamed back to user
```

**Why disaggregated?**
- Prefill is compute-bound (high GPU utilization, processes entire prompt at once)
- Decode is memory-bandwidth-bound (low GPU utilization, generates one token at a time)
- Separating them lets you scale each independently and use different GPU types/counts

**Verify:**
```bash
kubectl get pods -n team-alpha   # frontend + prefill + decode workers
kubectl get pods -n team-beta    # frontend + combined worker

# Test inference
kubectl port-forward svc/vllm-disagg-frontend 8000:8000 -n team-alpha &
curl localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"Qwen/Qwen3-0.6B","messages":[{"role":"user","content":"What is GPU MIG?"}],"max_tokens":50}'
kill %1
```

---

## Step 6: Generate Load

Simulates two teams using GPU differently — one heavy, one light.

```bash
./scripts/06-generate-load.sh
```

**What happens:**
- `team-alpha` (disaggregated): heavy load — continuous long-prompt requests → high prefill utilization
- `team-beta` (aggregated): light load — occasional short requests → moderate utilization
- Runs for 10 minutes then stops (enough for recording rules to populate)

**Verify (after 5 minutes):**
```bash
# Port-forward Prometheus
kubectl port-forward svc/prometheus-kube-prometheus-prometheus 9090:9090 -n monitoring &

# Check raw DCGM metrics have pod labels
curl -s 'http://localhost:9090/api/v1/query?query=DCGM_FI_PROF_GR_ENGINE_ACTIVE{pod!=""}' | python3 -m json.tool | head -30

# Check recording rules are producing data
curl -s 'http://localhost:9090/api/v1/query?query=namespace:gpu_cost_per_hour:sum' | python3 -m json.tool

kill %1
```

---

## Step 7: Validate End-to-End

Checks every layer of the pipeline.

```bash
./scripts/07-validate.sh
```

**Expected output:**
```
=== GPU Cost Attribution Validation ===

--- DCGM Metrics (raw) ---
  PASS: DCGM per-pod metrics exist (4 results)
  PASS: Per-pod has namespace label (4 results)

--- Recording Rules (Tier 1) ---
  PASS: Per-pod smoothed utilization (4 results)

--- Recording Rules (Tier 2) ---
  PASS: Namespace GPU count (2 results)
  PASS: Namespace avg utilization (2 results)

--- Recording Rules (Tier 3) ---
  PASS: Namespace cost per hour (2 results)
  PASS: Namespace waste fraction (2 results)

--- Pricing Exporter ---
  PASS: GPU price metric exists (1 results)

--- Per-Namespace Coverage ---
  PASS: team-alpha has cost data
  PASS: team-beta has cost data

--- Cost Summary ---
  team-alpha: $3.72/hr (2 GPUs, 73% avg util, 27% waste)
  team-beta:  $1.86/hr (1 GPU, 35% avg util, 65% waste)

=== Results: 11 passed, 0 failed ===
```

---

## Step 8: View in Grafana

```bash
kubectl port-forward svc/prometheus-grafana 3000:80 -n monitoring
# Open http://localhost:3000
# Login: admin / prom-operator
# Dashboard: "GPU Cost Attribution — Per Namespace"
```

**What you'll see:**
- Panel 1: GPU cost/hr by namespace (table)
- Panel 2: Waste % by namespace (gauge — team-beta should be red)
- Panel 3: GPU utilization over time (prefill workers spike, decode workers are steady-low)
- Panel 4: Dynamo disaggregated metrics (prefill vs decode latency breakdown)

---

## Step 9: Teardown

```bash
./scripts/99-destroy.sh
```

Deletes everything: DGDs, Dynamo platform, monitoring, GPU operator, EFS, cluster.
Takes ~5 minutes. Leaves no orphaned resources.

---

## Key Concepts to Understand

### Why DCGM already has pod labels (no kube-state-metrics join needed)

The GPU Operator sets `DCGM_EXPORTER_KUBERNETES=true`, which makes DCGM call the **kubelet PodResources gRPC API** on each node. This API returns: "device GPU-0 is assigned to pod X in namespace Y." DCGM enriches its own metric output with these labels at the source.

Without this flag, DCGM emits raw metrics like:
```
DCGM_FI_PROF_GR_ENGINE_ACTIVE{gpu="0"} 0.73
```

With the flag:
```
DCGM_FI_PROF_GR_ENGINE_ACTIVE{gpu="0",pod="vllm-prefill-xyz",namespace="team-alpha"} 0.73
```

### Why recording rules instead of raw Grafana queries

Recording rules pre-compute on the Prometheus write path (once per scrape interval). Raw PromQL joins in Grafana panels run on every dashboard refresh — expensive at scale. At 56 MIG slices, recording rules are mandatory.

### Why dynamic pricing

AWS changes GPU instance prices. Hardcoding `$1.86/hr` silently gives wrong chargeback after a price change. The pricing exporter calls the Price List API and exposes the current price as a Prometheus gauge.

### Dynamo's disaggregated architecture and cost implications

Disaggregated serving splits one user request across two GPU pools:
- **Prefill worker:** High SM utilization (70-95%) — efficient GPU use, low waste
- **Decode worker:** Low SM utilization (15-40%) — appears wasteful but is memory-bandwidth-bound (can't use SM harder)

This means cost attribution must understand that decode worker "waste" is inherent to auto-regressive generation, not inefficiency. The alert threshold (40%) should only fire for namespaces where the COMBINED prefill+decode average exceeds waste — not decode workers individually.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| GPU NodePool shows 0 nodes | No workload requesting GPU yet | Nodes appear when pods with `nvidia.com/gpu` requests are created |
| DCGM metrics missing pod labels | `DCGM_EXPORTER_KUBERNETES` not set | Re-run `02-install-gpu-operator.sh` |
| Recording rules show no data | Wait 5 minutes after load starts | Rules evaluate every 60s; 5m avg needs 5 min of data |
| Pricing exporter shows 0 | IRSA not configured or wrong region | Check pod logs: `kubectl logs -n monitoring -l app=gpu-pricing-exporter` |
| DGD pods stuck Pending | No GPU capacity | Check `kubectl describe pod` for scheduling errors; try different region |
