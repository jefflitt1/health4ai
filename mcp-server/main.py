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
import hashlib
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
    """Look up user_id from mcp_api_key hash in healthkit_api_keys."""
    key_hash = hashlib.sha256(mcp_api_key.encode()).hexdigest()
    try:
        conn = _connect()
        try:
            with conn.cursor() as cur:
                cur.execute(
                    "SELECT user_id FROM healthkit_api_keys "
                    "WHERE mcp_api_key_hash = %s AND NOT revoked",
                    (key_hash,),
                )
                row = cur.fetchone()
                return str(row[0]) if row else None
        finally:
            conn.close()
    except Exception as e:
        # Distinguish DB errors from missing-key (None) so callers can return 503 vs 401
        raise RuntimeError(f"DB error during key resolution: {e}") from e


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--transport", choices=["stdio", "http"], default="stdio")
    parser.add_argument("--port", type=int, default=8000)
    args = parser.parse_args()

    if args.transport == "http":
        # HTTP mode: FastMCP 3.x http_app with Starlette middleware for per-request auth
        from starlette.middleware import Middleware
        from starlette.middleware.base import BaseHTTPMiddleware
        from starlette.requests import Request as StarletteRequest
        from starlette.responses import JSONResponse, Response
        import uvicorn

        class AuthMiddleware(BaseHTTPMiddleware):
            async def dispatch(self, request: StarletteRequest, call_next):
                # Health check for Cloudflare tunnel and uptime monitors
                if request.method == "GET" and request.url.path in ("/", "/health"):
                    return Response(
                        '{"status":"ok","service":"health4ai-mcp"}',
                        media_type="application/json",
                    )
                auth = request.headers.get("Authorization", "")
                if auth.startswith("Bearer h4_mk_"):
                    mcp_key = auth[7:]
                    try:
                        uid = _resolve_user_from_mcp_key(mcp_key)
                    except RuntimeError:
                        return JSONResponse({"error": "Service temporarily unavailable"}, status_code=503)
                    if not uid:
                        return JSONResponse({"error": "Invalid or revoked MCP API key"}, status_code=401)
                    token = current_user_id.set(uid)
                    try:
                        response = await call_next(request)
                    finally:
                        current_user_id.reset(token)
                    return response
                elif DEFAULT_USER_ID and os.environ.get("MCP_AUTH_ENABLED", "").lower() == "true":
                    # Dev bypass explicitly opted in: single-user stdio-style access via HTTP
                    return await call_next(request)
                else:
                    return JSONResponse({"error": "Authorization required"}, status_code=401)

        app = mcp.http_app(middleware=[Middleware(AuthMiddleware)])
        uvicorn.run(app, host="0.0.0.0", port=args.port)
    else:
        mcp.run()
