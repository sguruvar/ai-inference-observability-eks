# GPU Cost Attribution with NVIDIA Dynamo + vLLM on EKS

Disaggregated LLM inference (prefill/decode split) with per-namespace GPU cost attribution.
Proves: Dynamo orchestrates vLLM workers → DCGM measures GPU utilization per pod → Prometheus recording rules compute cost → Grafana shows who's spending what.

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
