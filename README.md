
# GPU Cost Attribution with NVIDIA Dynamo + vLLM on EKS

Disaggregated LLM inference (prefill/decode split) with per-namespace GPU cost attribution.
Proves: Dynamo orchestrates vLLM workers → DCGM measures GPU utilization per pod → Prometheus recording rules compute cost → Grafana shows who's spending what.

## Why This Exists

Disaggregated LLM inference splits prefill and decode into separate workers — each with different GPU memory and compute profiles. Standard monitoring treats the whole inference request as a black box, making it impossible to answer: which team is consuming what GPU capacity, and at what cost?

This repo proves the full attribution chain: Dynamo disaggregates the workload → DCGM measures per-pod GPU utilization → Prometheus recording rules compute dollar cost per namespace → Grafana surfaces it as a dashboard any platform team can act on.

Built as a reference implementation for the [OpenTelemetry AI Inference blueprint](https://github.com/open-telemetry/opentelemetry.io/pull/10310) and the [NVIDIA DCGM Exporter dashboards](https://github.com/NVIDIA/dcgm-exporter/pull/674).

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│  EKS Cluster (Auto Mode)                                                │
│                                                                         │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │  Dynamo Platform (NATS + etcd + Operator)                       │   │
│  │                                                                 │   │
│  │  DynamoGraphDeployment: vllm-disagg                             │   │
│  │  ┌──────────────┐  ┌────────────────┐  ┌───────────────────┐  │   │
│  │  │  Frontend    │  │ PrefillWorker  │  │  DecodeWorker     │  │   │
│  │  │  (router)    │  │ (GPU, compute) │  │  (GPU, memory)    │  │   │
│  │  └──────┬───────┘  └───────┬────────┘  └────────┬──────────┘  │   │
│  │         │                   │ NIXL KV transfer   │             │   │
│  │         └───────────────────┴────────────────────┘             │   │
│  └─────────────────────────────────────────────────────────────────┘   │
│                                                                         │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │  Observability Stack                                            │   │
│  │                                                                 │   │
│  │  DCGM Exporter ──→ Prometheus ──→ Recording Rules ──→ Grafana  │   │
│  │  (per-pod GPU      (scrape)       (cost math)        (dashboard│   │
│  │   utilization)                                        + alerts) │   │
│  │                                                                 │   │
│  │  Pricing Exporter (AWS Price List API → $/GPU/hr gauge)        │   │
│  └─────────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────┘
```

## Two Modes

| Mode | Instance | GPU | MIG? | Cost/hr | Availability |
|------|----------|-----|------|---------|--------------|
| **Quick Demo** | g6e.2xlarge | 1× L40S 48GB | No | ~$1.86 | Easy (spot) |
| **Full MIG** | p5.48xlarge | 8× H100 80GB | Yes (56 slices) | ~$98 | Hard (reserved/ODCR) |

Both modes prove the same point: Dynamo disaggregated serving → DCGM metrics → cost attribution.
MIG mode additionally proves multi-tenant GPU slicing.

## What's Included

| Artifact | Location | Description |
|---|---|---|
| Kubernetes manifests | `manifests/` | Dynamo, vLLM workers, DCGM exporter, Prometheus stack |
| Cluster scripts | `scripts/` | End-to-end deploy and teardown — each step is copy-paste |
| Prometheus recording rules | `manifests/recording-rules.yaml` | Cost math: GPU util × $/GPU/hr → $/namespace |
| Grafana dashboards | `manifests/dashboards/` | Cost attribution, KEDA autoscaling, disaggregated inference |
| MCP server | `mcp-server/` | Query Prometheus metrics via natural language |
| Runbooks | `runbooks/` | GPU saturation, KV cache eviction, KEDA scaling lag |
| Blog walkthrough | `BLOG.md` | Step-by-step narrative with expected outputs at each stage |

## Prerequisites

- AWS CLI configured (`aws sts get-caller-identity` works)
- eksctl, kubectl, helm installed
- HuggingFace token (free, for model download): https://huggingface.co/settings/tokens

## Usage

Follow the blog: [BLOG.md](BLOG.md) — each section is a copy-paste block.

Quick version:
```bash
# Set your HF token
export HF_TOKEN="hf_xxxxxxxxxxxxx"

# Full deploy (~20 min)
./scripts/01-create-cluster.sh
./scripts/02-install-gpu-operator.sh
./scripts/03-install-dynamo.sh
./scripts/04-install-monitoring.sh
./scripts/05-deploy-inference.sh
./scripts/06-generate-load.sh

# Validate
./scripts/07-validate.sh

# Access dashboards
kubectl port-forward svc/prometheus-grafana 3000:80 -n monitoring
# → http://localhost:3000 (admin / prom-operator)

# Teardown
./scripts/99-destroy.sh
```

## Cost to Run

Quick demo mode: ~$4/hr (g6e.2xlarge × 3 GPU nodes + system nodes via Auto Mode)
Run for 1-2 hours, then destroy. Total cost: $5-8.

## Related Work

- [NVIDIA DCGM Exporter PR #674](https://github.com/NVIDIA/dcgm-exporter/pull/674) — Three Grafana dashboards (cost attribution, KEDA autoscaling, disaggregated inference) contributed upstream to NVIDIA
- [OpenTelemetry AI Inference Blueprint PR #10310](https://github.com/open-telemetry/opentelemetry.io/pull/10310) — Architecture from this repo contributed as an OTel community blueprint
- [GPU Cost Attribution with NVIDIA Dynamo (Medium)](https://medium.com/@sivagurunath/gpu-cost-attribution-for-disaggregated-llm-inference-with-nvidia-dynamo-34815fd55ea4) — Article walkthrough
- [Per-Namespace GPU Cost Attribution on EKS with NVIDIA MIG (Medium)](https://medium.com/@sivagurunath/per-namespace-gpu-cost-attribution-on-eks-with-nvidia-mig-9dde0f82b6e4) — MIG mode deep dive

## Citation

If you use this in a talk, blog, or paper:

```
@misc{ai-inference-observability-eks,
  author = {Siva Guruvareddiar},
  title  = {AI Inference Observability on EKS},
  year   = {2026},
  url    = {https://github.com/sguruvar/ai-inference-observability-eks}
}
```

