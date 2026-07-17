# Contributing

Contributions welcome. Here's how to get started.

## What we're looking for

- Additional inference frameworks (TensorRT-LLM, SGLang, Triton)
- New Grafana dashboard panels (latency percentiles, token throughput, TTFT)
- Cloud provider ports (GKE, AKS)
- Bug fixes in scripts or manifests
- Corrections to recording rule math

## How to contribute

1. Open an issue first describing what you want to add — avoids duplicate work
2. Fork the repo and create a branch: `git checkout -b your-feature`
3. Test your change using Quick Demo mode (g6e.2xlarge, ~$4/hr total)
4. Open a PR with: what you changed, why, and validation output from `./scripts/07-validate.sh`

## Running locally (Quick Demo)

```bash
export HF_TOKEN="hf_xxxxxxxxxxxxx"
./scripts/01-create-cluster.sh
./scripts/02-install-gpu-operator.sh
./scripts/03-install-dynamo.sh
./scripts/04-install-monitoring.sh
./scripts/05-deploy-inference.sh
./scripts/06-generate-load.sh
./scripts/07-validate.sh
```

Expected: Grafana dashboard at `localhost:3000` showing per-namespace GPU cost.

## Questions

Open an issue or find me on [LinkedIn](https://linkedin.com/in/sguruvar).
