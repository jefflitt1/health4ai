"""
health4ai — MCP Server
Exposes Apple Health data from Supabase as MCP tool calls.

Modes:
  stdio (default): python main.py
  http  (hosted):  python main.py --transport http [--port 8000]
    Auth: Bearer h4_mk_... in Authorization header
    Each request is scoped to the user identified by the MCP API key.
"""

import argparse
import os

from dotenv import load_dotenv
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
    search_records,
    get_metric_stats,
    compare_periods,
    current_user_id,
    DEFAULT_USER_ID,
    _connect,
)

load_dotenv()

mcp = FastMCP(
    name="health4ai",
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
mcp.tool()(search_records)
mcp.tool()(get_metric_stats)
mcp.tool()(compare_periods)


def _resolve_user_from_mcp_key(mcp_api_key: str) -> str | None:
    """Look up user_id from mcp_api_key in healthkit_api_keys."""
    try:
        conn = _connect()
        try:
            with conn.cursor() as cur:
                cur.execute(
                    "SELECT user_id FROM healthkit_api_keys "
                    "WHERE mcp_api_key = %s AND NOT revoked",
                    (mcp_api_key,),
                )
                row = cur.fetchone()
                return str(row[0]) if row else None
        finally:
            conn.close()
    except Exception:
        return None


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--transport", choices=["stdio", "http"], default="stdio")
    parser.add_argument("--port", type=int, default=8000)
    args = parser.parse_args()

    if args.transport == "http":
        # HTTP mode: wrap with Starlette middleware for per-request auth
        from starlette.applications import Starlette
        from starlette.middleware.base import BaseHTTPMiddleware
        from starlette.requests import Request as StarletteRequest
        from starlette.responses import JSONResponse
        import uvicorn

        class AuthMiddleware(BaseHTTPMiddleware):
            async def dispatch(self, request: StarletteRequest, call_next):
                auth = request.headers.get("Authorization", "")
                if auth.startswith("Bearer h4_mk_"):
                    mcp_key = auth[7:]
                    uid = _resolve_user_from_mcp_key(mcp_key)
                    if not uid:
                        return JSONResponse({"error": "Invalid or revoked MCP API key"}, status_code=401)
                    token = current_user_id.set(uid)
                    try:
                        response = await call_next(request)
                    finally:
                        current_user_id.reset(token)
                    return response
                elif DEFAULT_USER_ID:
                    # Single-user fallback (dev mode — no auth header required)
                    return await call_next(request)
                else:
                    return JSONResponse({"error": "Authorization required"}, status_code=401)

        app = mcp.get_asgi_app()
        wrapped = Starlette(routes=app.routes if hasattr(app, 'routes') else [])
        # Apply middleware to the FastMCP ASGI app directly
        from starlette.middleware import Middleware
        from starlette.types import ASGIApp

        class WrappedApp:
            def __init__(self, inner: ASGIApp):
                self._middleware = AuthMiddleware(inner)

            async def __call__(self, scope, receive, send):
                await self._middleware(scope, receive, send)

        uvicorn.run(WrappedApp(app), host="0.0.0.0", port=args.port)
    else:
        mcp.run()
