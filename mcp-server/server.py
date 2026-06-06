"""
GPU Platform MCP Server — exposes GPU cost attribution platform as tools for AI agents.

Uses FastMCP with Streamable HTTP transport (production-ready, stateless).
Run: python server.py (starts on port 8080)
"""
import json
import logging
import os
import subprocess
from typing import Any

from mcp.server.fastmcp import FastMCP

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
logger = logging.getLogger(__name__)

PROMETHEUS_URL = os.environ.get(
    "PROMETHEUS_URL",
    "http://prometheus-kube-prometheus-prometheus.monitoring.svc.cluster.local:9090",
)

mcp = FastMCP(
    "gpu-platform",
    host="0.0.0.0",
    port=8080,
    streamable_http_path="/mcp",
    stateless_http=True,
)


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


@mcp.tool()
def get_gpu_cost_by_team(team: str = "") -> str:
    """Get GPU cost per hour for each team (DGD). Shows allocated cost based on
    real-time AWS pricing x GPU/MIG slice count."""

    results = query_prometheus("deployment:gpu_cost_per_hour:sum")
    if not results:
        return "No cost data available. Recording rules may need time to evaluate."

    lines = ["| Team (DGD) | Cost/hr | GPUs | Utilization |", "|---|---|---|---|"]

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


@mcp.tool()
def get_waste_report(team: str = "") -> str:
    """Get GPU waste analysis per team. Waste = allocated capacity sitting idle.
    High waste (>40%) means paying for GPUs that aren't doing work."""

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
        severity = "CRITICAL" if waste > 0.7 else "WARNING" if waste > 0.4 else "OK"
        lines.append(f"### {dgd} — {severity}")
        lines.append(f"- Waste: {waste:.1%}")
        lines.append(f"- Wasted cost: ${wasted_dollars:.2f}/hr")
        if waste > 0.4:
            lines.append(f"- Recommendation: Scale down or reduce MIG allocation")
        lines.append("")

    return "\n".join(lines)


@mcp.tool()
def get_mig_status() -> str:
    """Get MIG slice allocation status on GPU nodes."""

    output = run_kubectl(
        "get nodes -l workload=gpu -o jsonpath="
        "'{range .items[*]}{.metadata.name} mig-config={.metadata.labels.nvidia\\.com/mig\\.config} "
        "state={.metadata.labels.nvidia\\.com/mig\\.config\\.state} "
        "slices={.status.allocatable.nvidia\\.com/mig-3g\\.20gb}{\"\\n\"}{end}'"
    )
    if not output:
        return "No GPU nodes with MIG configuration found."

    return f"## MIG Status\n```\n{output}\n```"


@mcp.tool()
def get_scaling_status() -> str:
    """Get KEDA autoscaling status for prefill and decode workers."""

    scaled_objects = run_kubectl("get scaledobject -n dynamo-system -o wide --no-headers")
    hpas = run_kubectl("get hpa -n dynamo-system --no-headers")

    return f"## KEDA Scaling Status\n\n### ScaledObjects\n```\n{scaled_objects or 'None'}\n```\n\n### HPAs\n```\n{hpas or 'None'}\n```"


@mcp.tool()
def scale_workers(dgd: str, component: str, replicas: int) -> str:
    """Scale prefill or decode workers for a DGD.

    Args:
        dgd: DGD name (e.g., 'vllm-disagg')
        component: 'prefill' or 'decode'
        replicas: target count (0-8)
    """
    if replicas < 0 or replicas > 8:
        return "Error: replicas must be 0-8"
    if component not in ("prefill", "decode"):
        return "Error: component must be 'prefill' or 'decode'"

    deployments = run_kubectl("get deployments -n dynamo-system --no-headers -o custom-columns='NAME:.metadata.name'")
    target = None
    for dep in deployments.split("\n"):
        if dgd in dep and component in dep.lower():
            target = dep.strip()
            break

    if not target:
        return f"Error: no deployment found for dgd='{dgd}' component='{component}'"

    result = run_kubectl(f"scale deployment {target} -n dynamo-system --replicas={replicas}")
    return f"Scaled {target} to {replicas} replicas. {result}"


if __name__ == "__main__":
    mcp.run(transport="streamable-http")
