# Runbook: High GPU Waste by Namespace

**Alert:** `HighGPUWasteByNamespace` (waste > 40% for 10 min)

## Understanding the Alert

GPU waste = allocated cost - effective cost. A namespace with 40% waste is paying for GPU capacity it's not using.

**Important for disaggregated serving:** Decode workers inherently have lower SM utilization (~15-40%) because auto-regressive token generation is memory-bandwidth-bound, not compute-bound. This is NOT inefficiency — it's the nature of the workload. Only alert on the namespace-level AVERAGE (prefill + decode combined).

## Step 1: Identify which pods are underutilized

```bash
kubectl port-forward svc/prometheus-kube-prometheus-prometheus 9090:9090 -n monitoring &

# Per-pod utilization in the alerting namespace
curl -s 'http://localhost:9090/api/v1/query' \
  --data-urlencode 'query=namespace_pod:gpu_utilization:avg5m{namespace="<NAMESPACE>"}' | python3 -m json.tool
```

## Step 2: Check if it's a prefill or decode worker

```bash
# If pod name contains "prefill" and utilization is low → something is wrong (prefill should be high)
# If pod name contains "decode" and utilization is low → may be normal for auto-regressive generation

kubectl get pods -n <NAMESPACE> -o wide
kubectl logs -n <NAMESPACE> <POD_NAME> --tail=20
```

## Step 3: Check request rate (is the model receiving traffic?)

```bash
# Check Dynamo frontend request count
curl -s 'http://localhost:9090/api/v1/query' \
  --data-urlencode 'query=rate(dynamo_frontend_requests_total{namespace="<NAMESPACE>"}[5m])'

# If 0 requests → model is idle but allocated. Scale down.
```

## Step 4: Check GPU memory usage (model loaded but not serving?)

```bash
curl -s 'http://localhost:9090/api/v1/query' \
  --data-urlencode 'query=DCGM_FI_DEV_FB_USED{namespace="<NAMESPACE>"}'

# High FB_USED + low utilization = model is loaded but idle
# This is the most common cause of GPU waste
```

## Step 5: Recommended actions

| Scenario | Action |
|----------|--------|
| Model loaded but 0 requests | Scale replicas to 0 (KEDA scale-to-zero) |
| Decode worker low util (15-35%) | **Normal** — memory-bound workload. No action. |
| Prefill worker low util (< 50%) | Check batch size — may need more concurrent requests |
| All workers idle for > 1 hour | Delete DGD or scale down: `kubectl scale dgd <name> --replicas=0 -n <NS>` |

## Step 6: Long-term fix

- Use KEDA with Prometheus scaler to scale-to-zero on idle
- Set `minReplicaCount: 0` in ScaledObject
- Cold-start latency (~30s for small models) is acceptable vs paying $/hr for idle GPUs
