"""
Local stdio version of the GPU Platform MCP server.
Run with Claude Desktop or Claude Code for local testing.

Requires:
  - kubectl configured (pointing to the GPU cluster)
  - kubectl port-forward svc/prometheus-kube-prometheus-prometheus 9090:9090 -n monitoring

Add to Claude Desktop config (~/.claude/claude_desktop_config.json):
{
  "mcpServers": {
    "gpu-platform": {
      "command": "python",
      "args": ["/path/to/mcp-server/local.py"]
    }
  }
}
"""
import os

os.environ.setdefault("PROMETHEUS_URL", "http://localhost:9090")

from server import mcp

if __name__ == "__main__":
    mcp.run(transport="stdio")
