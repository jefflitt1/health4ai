"""
HealthKit Bridge — MCP Server
Exposes Apple Health data from Supabase as Claude Code tool calls.
Run: python main.py
"""

from fastmcp import FastMCP
from tools import (
    get_health_summary,
    get_sleep,
    get_hrv_trend,
    query_metric,
    get_workouts,
    get_daily_snapshot,
    get_long_term_trend,
    get_coaching_brief,
)

mcp = FastMCP(
    name="healthkit-bridge",
    instructions="Query your Apple Health data — sleep, HRV, workouts, steps, and more.",
)

mcp.tool()(get_health_summary)
mcp.tool()(get_sleep)
mcp.tool()(get_hrv_trend)
mcp.tool()(query_metric)
mcp.tool()(get_workouts)
mcp.tool()(get_daily_snapshot)
mcp.tool()(get_long_term_trend)
mcp.tool()(get_coaching_brief)

if __name__ == "__main__":
    mcp.run()
