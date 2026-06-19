// CF Pages Function: health4.ai/register/* → Supabase health4-register
// Catches /register/setup, /register/register, /register/validate, /register/revoke

const UPSTREAM_BASE = "https://donnmhbwhpjlmpnwgdqr.supabase.co/functions/v1/health4-register"

export async function onRequest(ctx) {
  const url = new URL(ctx.request.url)
  // Strip /register prefix to get the sub-path (/setup, /validate?token=..., etc.)
  const suffix = url.pathname.replace(/^\/register/, "") + url.search

  const req = new Request(`${UPSTREAM_BASE}${suffix}`, {
    method: ctx.request.method,
    headers: ctx.request.headers,
    body: ["GET", "HEAD"].includes(ctx.request.method) ? undefined : ctx.request.body,
  })

  const resp = await fetch(req)
  const headers = new Headers(resp.headers)
  headers.set("Access-Control-Allow-Origin", "*")
  headers.set("Access-Control-Allow-Headers", "Authorization, Content-Type")
  return new Response(resp.body, { status: resp.status, headers })
}
