// health4.ai API proxy — Cloudflare Worker
// Routes api.health4.ai/* → Supabase Edge Functions
// Decouples the iOS binary from the Supabase project ref.
//
// /ingest      → healthkit-ingest  (POST only — HealthKit data write)
// /register/*  → health4-register  (setup, register, validate, revoke)
// /            → health check

const SUPABASE_BASE = "https://donnmhbwhpjlmpnwgdqr.supabase.co/functions/v1"

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url)
    const path = url.pathname

    if (path === "/" && request.method === "GET") {
      return new Response(JSON.stringify({ status: "ok", service: "health4.ai API" }), {
        headers: { "Content-Type": "application/json" },
      })
    }

    let upstream
    if (path === "/ingest") {
      upstream = `${SUPABASE_BASE}/healthkit-ingest`
    } else if (path.startsWith("/register")) {
      const suffix = path.slice("/register".length) // e.g. "/setup", "/validate", ""
      upstream = `${SUPABASE_BASE}/health4-register${suffix}${url.search}`
    } else {
      return new Response(JSON.stringify({ error: "Not found" }), {
        status: 404,
        headers: { "Content-Type": "application/json" },
      })
    }

    // Forward the request with all original headers intact
    const proxyReq = new Request(upstream, {
      method: request.method,
      headers: request.headers,
      body: request.body,
      redirect: "follow",
    })

    const resp = await fetch(proxyReq)

    // Pass response through with CORS headers added
    const newHeaders = new Headers(resp.headers)
    newHeaders.set("Access-Control-Allow-Origin", "*")
    newHeaders.set("Access-Control-Allow-Headers", "Authorization, Content-Type")

    return new Response(resp.body, {
      status: resp.status,
      statusText: resp.statusText,
      headers: newHeaders,
    })
  },
}
