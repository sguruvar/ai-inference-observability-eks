#!/usr/bin/env bash
set -euo pipefail

# Installs NVIDIA GPU Operator with DCGM Kubernetes integration mode.
# This enables DCGM to attach pod/namespace labels to GPU metrics via kubelet PodResources API.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

echo "=== Step 1/3: Adding NVIDIA Helm repo ==="
helm repo add nvidia https://helm.ngc.nvidia.com/nvidia
helm repo update nvidia

echo ""
echo "=== Step 2/3: Creating GPU Operator namespace + DCGM metrics config ==="
kubectl create namespace gpu-operator --dry-run=client -o yaml | kubectl apply -f -

# Custom DCGM metrics — includes NVLink profiling for Dynamo's NIXL transfers
kubectl apply -f "$PROJECT_ROOT/manifests/monitoring/dcgm-metrics-config.yaml"

echo ""
echo "=== Step 3/3: Installing GPU Operator ==="
echo "Key settings:"
echo "  - DCGM_EXPORTER_KUBERNETES=true → pod labels on GPU metrics (via kubelet PodResources API)"
echo "  - serviceMonitor.enabled=true → Prometheus auto-discovers DCGM"
echo "  - serviceMonitor.honorLabels=true → keeps workload pod/namespace labels"
echo ""

helm upgrade --install gpu-operator nvidia/gpu-operator \
  --namespace gpu-operator \
  --set operator.defaultRuntime=containerd \
  --set driver.enabled=true \
  --set toolkit.enabled=true \
  --set devicePlugin.enabled=true \
  --set dcgmExporter.enabled=true \
  --set dcgmExporter.config.name=dcgm-exporter-metrics-config \
  --set dcgmExporter.env[0].name=DCGM_EXPORTER_KUBERNETES \
  --set-string dcgmExporter.env[0].value="true" \
  --set dcgmExporter.serviceMonitor.enabled=true \
  --set dcgmExporter.serviceMonitor.honorLabels=true \
  --set dcgmExporter.serviceMonitor.additionalLabels.release=prometheus \
  --set dcgmExporter.serviceMonitor.interval=30s \
  --set migManager.enabled=true \
  --set migManager.env[0].name=WITH_REBOOT \
  --set-string migManager.env[0].value="true" \
  --set nodeStatusExporter.enabled=true \
  --set node-feature-discovery.enabled=true \
  --wait --timeout=600s

echo ""
echo "=== GPU Operator installed ==="
echo ""
echo "GPU Operator components will start once a GPU node is provisioned."
echo "DCGM will automatically report per-pod GPU metrics with namespace labels."
echo ""
echo "How it works:"
echo "  1. GPU Operator deploys DCGM Exporter DaemonSet on every GPU node"
echo "  2. DCGM_EXPORTER_KUBERNETES=true makes DCGM call kubelet PodResources API"
echo "  3. kubelet tells DCGM: 'GPU device 0 → pod X in namespace Y'"
echo "  4. DCGM attaches pod/namespace labels to every metric it emits"
echo "  5. honorLabels=true on ServiceMonitor tells Prometheus to keep these labels"
echo ""
echo "Next: ./scripts/03-install-dynamo.sh"
