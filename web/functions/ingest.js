// CF Pages Function: health4.ai/ingest → Supabase healthkit-ingest
// Proxies HealthKit data writes. Decouples iOS binary from Supabase project ref.

const UPSTREAM = "https://donnmhbwhpjlmpnwgdqr.supabase.co/functions/v1/healthkit-ingest"

export async function onRequestPost(ctx) {
  const req = new Request(UPSTREAM, {
    method: "POST",
    headers: ctx.request.headers,
    body: ctx.request.body,
  })
  const resp = await fetch(req)
  const headers = new Headers(resp.headers)
  headers.set("Access-Control-Allow-Origin", "*")
  return new Response(resp.body, { status: resp.status, headers })
}

export async function onRequestOptions() {
  return new Response(null, {
    status: 204,
    headers: {
      "Access-Control-Allow-Origin": "*",
      "Access-Control-Allow-Methods": "POST, OPTIONS",
      "Access-Control-Allow-Headers": "Authorization, Content-Type",
    },
  })
}
