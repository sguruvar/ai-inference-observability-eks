"""
GPU Platform MCP Server — exposes GPU cost attribution platform as tools for AI agents.

Transport: Streamable HTTP (production-ready, stateless, works behind K8s ALB)
Tools:
  - get_gpu_cost_by_team: per-team GPU cost from Prometheus recording rules
  - get_waste_report: waste % per DGD with recommendations
  - get_mig_status: MIG slice allocation on GPU nodes
  - get_scaling_status: KEDA ScaledObject status and recent scale events
  - scale_workers: scale prefill/decode workers for a DGD

Runs as: uvicorn server:app --host 0.0.0.0 --port 8080
Consumers connect: MCP client SDK → http://gpu-mcp-server:8080/mcp
"""
import json
import logging
import os
import subprocess
from typing import Any

from mcp.server import Server
from mcp.server.streamable_http import StreamableHTTPServer

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
logger = logging.getLogger(__name__)

PROMETHEUS_URL = os.environ.get(
    "PROMETHEUS_URL",
    "http://prometheus-kube-prometheus-prometheus.monitoring.svc.cluster.local:9090",
)

server = Server("gpu-platform")


def query_prometheus(promql: str) -> list[dict[str, Any]]:
    """Query Prometheus and return results."""
    import urllib.request
    import urllib.parse

    url = f"{PROMETHEUS_URL}/api/v1/query"
    data = urllib.parse.urlencode({"query": promql}).encode()
    req = urllib.request.Request(url, data=data, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            result = json.loads(resp.read())
            return result.get("data", {}).get("result", [])
    except Exception as e:
        logger.error(f"Prometheus query failed: {e}")
        return []


def run_kubectl(args: str) -> str:
    """Run a kubectl command and return output."""
    try:
        result = subprocess.run(
            f"kubectl {args}",
            shell=True,
            capture_output=True,
            text=True,
            timeout=30,
        )
        return result.stdout.strip() or result.stderr.strip()
    except Exception as e:
        return f"Error: {e}"


@server.tool()
async def get_gpu_cost_by_team(team: str = "") -> str:
    """Get GPU cost per hour for each team (DGD). Shows allocated cost based on
    real-time AWS pricing × GPU/MIG slice count. If team is specified, filters to that team."""

    results = query_prometheus("deployment:gpu_cost_per_hour:sum")
    if not results:
        return "No cost data available. Recording rules may need time to evaluate (wait 5 min after workload starts)."

    lines = ["| Team (DGD) | Cost/hr | GPUs | Utilization |"]
    lines.append("|---|---|---|---|")

    util_results = query_prometheus("deployment:gpu_utilization:avg")
    util_map = {r["metric"].get("dgd", ""): float(r["value"][1]) for r in util_results}

    count_results = query_prometheus("deployment:gpu_allocated:count")
    count_map = {r["metric"].get("dgd", ""): r["value"][1] for r in count_results}

    for r in sorted(results, key=lambda x: x["metric"].get("dgd", "")):
        dgd = r["metric"].get("dgd", "unknown")
        if team and team not in dgd:
            continue
        cost = float(r["value"][1])
        gpus = count_map.get(dgd, "?")
        util = util_map.get(dgd, 0)
        lines.append(f"| {dgd} | ${cost:.2f} | {gpus} | {util:.1%} |")

    return "\n".join(lines)


@server.tool()
async def get_waste_report(team: str = "") -> str:
    """Get GPU waste analysis per team. Waste = allocated capacity that's sitting idle.
    Includes recommendations for right-sizing. High waste (>40%) means the team is
    paying for GPUs that aren't doing work."""

    results = query_prometheus("deployment:gpu_waste_fraction:ratio")
    if not results:
        return "No waste data available yet."

    cost_results = query_prometheus("deployment:gpu_cost_per_hour:sum")
    cost_map = {r["metric"].get("dgd", ""): float(r["value"][1]) for r in cost_results}

    lines = ["## GPU Waste Report\n"]

    for r in sorted(results, key=lambda x: float(x["value"][1]), reverse=True):
        dgd = r["metric"].get("dgd", "unknown")
        if team and team not in dgd:
            continue
        waste = float(r["value"][1])
        cost = cost_map.get(dgd, 0)
        wasted_dollars = cost * waste

        severity = "🔴 CRITICAL" if waste > 0.7 else "🟡 WARNING" if waste > 0.4 else "🟢 OK"
        lines.append(f"### {dgd} — {severity}")
        lines.append(f"- Waste: {waste:.1%}")
        lines.append(f"- Wasted cost: ${wasted_dollars:.2f}/hr (${wasted_dollars * 24:.0f}/day)")
        lines.append(f"- Total allocated: ${cost:.2f}/hr")

        if waste > 0.7:
            lines.append(f"- **Recommendation:** Scale down immediately or reduce GPU/MIG allocation")
        elif waste > 0.4:
            lines.append(f"- **Recommendation:** Consider reducing replicas or switching to smaller MIG slices")
        lines.append("")

    return "\n".join(lines)


@server.tool()
async def get_mig_status() -> str:
    """Get MIG (Multi-Instance GPU) slice allocation status on GPU nodes.
    Shows total slices available, slices in use, and which node has MIG configured."""

    output = run_kubectl(
        "get nodes -l workload=gpu -o jsonpath="
        "'{range .items[*]}{.metadata.name} mig-config={.metadata.labels.nvidia\\.com/mig\\.config} "
        "state={.metadata.labels.nvidia\\.com/mig\\.config\\.state} "
        "allocatable-mig={.status.allocatable.nvidia\\.com/mig-3g\\.20gb}{\"\\n\"}{end}'"
    )

    if not output or "No resources" in output:
        return "No GPU nodes with MIG configuration found."

    pod_output = run_kubectl(
        "get pods -n dynamo-system -l nvidia.com/dynamo-graph-deployment-name "
        "--no-headers -o custom-columns='NAME:.metadata.name,STATUS:.status.phase'"
    )

    lines = ["## MIG Status\n"]
    lines.append("### Nodes")
    lines.append(f"```\n{output}\n```\n")
    lines.append("### GPU Pods on MIG Slices")
    lines.append(f"```\n{pod_output or 'No GPU pods running'}\n```")

    return "\n".join(lines)


@server.tool()
async def get_scaling_status() -> str:
    """Get KEDA autoscaling status for prefill and decode workers.
    Shows current replicas, scaling signals, and whether ScaledObjects are active."""

    scaled_objects = run_kubectl("get scaledobject -n dynamo-system -o wide --no-headers")
    hpas = run_kubectl("get hpa -n dynamo-system --no-headers")

    prefill_util = query_prometheus(
        'sum(DCGM_FI_PROF_GR_ENGINE_ACTIVE{pod=~".*prefill.*",namespace="dynamo-system"})'
    )
    decode_mem = query_prometheus(
        'avg(DCGM_FI_DEV_FB_USED{pod=~".*decode.*",namespace="dynamo-system"} / '
        '(DCGM_FI_DEV_FB_USED{pod=~".*decode.*",namespace="dynamo-system"} + '
        'DCGM_FI_DEV_FB_FREE{pod=~".*decode.*",namespace="dynamo-system"}))'
    )

    lines = ["## KEDA Scaling Status\n"]
    lines.append("### ScaledObjects")
    lines.append(f"```\n{scaled_objects or 'None found'}\n```\n")
    lines.append("### HPAs (created by KEDA)")
    lines.append(f"```\n{hpas or 'None found'}\n```\n")
    lines.append("### Current Scaling Signals")

    if prefill_util:
        val = float(prefill_util[0]["value"][1])
        lines.append(f"- Prefill GPU utilization: {val:.1%} (threshold: 70%)")
    if decode_mem:
        val = float(decode_mem[0]["value"][1])
        lines.append(f"- Decode memory pressure: {val:.1%} (threshold: 80%)")

    return "\n".join(lines)


@server.tool()
async def scale_workers(dgd: str, component: str, replicas: int) -> str:
    """Scale prefill or decode workers for a DynamoGraphDeployment.
    Use this to right-size GPU allocation based on waste report findings.

    Args:
        dgd: DGD name (e.g., 'vllm-disagg' or 'vllm-agg')
        component: Which component to scale ('prefill' or 'decode')
        replicas: Target replica count (0 to scale down, max 8 for MIG slices)
    """
    if replicas < 0 or replicas > 8:
        return "Error: replicas must be between 0 and 8 (limited by MIG slice count)"

    if component not in ("prefill", "decode"):
        return "Error: component must be 'prefill' or 'decode'"

    # Find the deployment name
    deployments = run_kubectl(
        f"get deployments -n dynamo-system --no-headers -o custom-columns='NAME:.metadata.name'"
    )

    target = None
    for dep in deployments.split("\n"):
        if dgd in dep and component in dep.lower():
            target = dep.strip()
            break

    if not target:
        return f"Error: no deployment found matching dgd='{dgd}' component='{component}'"

    result = run_kubectl(f"scale deployment {target} -n dynamo-system --replicas={replicas}")
    return f"Scaled {target} to {replicas} replicas. {result}"


# Create the Streamable HTTP app
app = StreamableHTTPServer(server, path="/mcp").app
