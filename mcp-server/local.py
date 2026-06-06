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

from server import server

if __name__ == "__main__":
    from mcp.server.stdio import stdio_server
    import asyncio

    async def main():
        async with stdio_server() as (read, write):
            await server.run(read, write, server.create_initialization_options())

    asyncio.run(main())
