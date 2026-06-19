// HealthKit Bridge — Supabase Edge Function: healthkit-ingest
// Receives batched HealthKit samples from the iOS app and upserts into public.healthkit_metrics
// Deploy: supabase functions deploy healthkit-ingest

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!
const SUPABASE_ANON_KEY = Deno.env.get('SUPABASE_ANON_KEY')!
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!

interface HealthSample {
  metric_type: string
  value: number | null
  unit: string
  source_device: string
  started_at: string
  ended_at: string | null
  metadata: Record<string, unknown> | null
}

interface IngestPayload {
  samples: HealthSample[]
}

Deno.serve(async (req: Request) => {
  if (req.method !== 'POST') {
    return new Response('Method Not Allowed', { status: 405 })
  }

  // Validate bearer token — two paths:
  // 1. h4_sk_... (health4.ai hosted tier API key) → lookup in healthkit_api_keys
  // 2. Supabase JWT → validate via auth.getUser()
  const authHeader = req.headers.get('Authorization')
  if (!authHeader?.startsWith('Bearer ')) {
    return json({ error: 'Missing Authorization header' }, 401)
  }
  const bearer = authHeader.slice(7)

  const adminClient = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY)
  let userId: string

  if (bearer.startsWith('h4_sk_')) {
    // Hosted tier: validate sync_token
    const { data: keyRow, error: keyErr } = await adminClient
      .from('healthkit_api_keys')
      .select('user_id')
      .eq('sync_token', bearer)
      .eq('revoked', false)
      .single()
    if (keyErr || !keyRow) return json({ error: 'Invalid or revoked sync token' }, 401)
    userId = keyRow.user_id
    // Track last_sync timestamp
    await adminClient
      .from('healthkit_api_keys')
      .update({ last_sync: new Date().toISOString() })
      .eq('sync_token', bearer)
  } else {
    // Self-hosted: validate Supabase JWT
    const userClient = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
      global: { headers: { Authorization: `Bearer ${bearer}` } },
    })
    const { data: { user }, error: authError } = await userClient.auth.getUser()
    if (authError || !user) return json({ error: 'Unauthorized' }, 401)
    userId = user.id
  }

  // Parse payload
  let payload: IngestPayload
  try {
    payload = await req.json()
  } catch {
    return json({ error: 'Invalid JSON body' }, 400)
  }

  if (!Array.isArray(payload.samples) || payload.samples.length === 0) {
    return json({ inserted: 0 })
  }

  // Validate sample count (max 1000 per request)
  if (payload.samples.length > 1000) {
    return json({ error: 'Batch size exceeds maximum of 1000 samples' }, 400)
  }

  // Reject unbounded string fields (data integrity + storage cost guard)
  const MAX_STR = 256
  for (const s of payload.samples) {
    if (
      (s.metric_type?.length ?? 0) > MAX_STR ||
      (s.unit?.length ?? 0) > MAX_STR ||
      (s.source_device?.length ?? 0) > MAX_STR
    ) {
      return json({ error: 'String field exceeds maximum length of 256' }, 400)
    }
  }

  // Attach user_id to all rows
  const rows = payload.samples.map((s) => ({
    user_id: userId,
    metric_type: s.metric_type,
    value: s.value ?? null,
    unit: s.unit,
    source_device: s.source_device,
    started_at: s.started_at,
    ended_at: s.ended_at ?? null,
    metadata: s.metadata ?? null,
  }))

  // Deduplicate within the batch on the DB conflict key (user_id is constant per request,
  // so metric_type|started_at is sufficient). HK can emit the same timestamp from multiple
  // source devices; PostgreSQL UPSERT rejects intra-batch dupes ("cannot affect row twice").
  // NOTE: this collapses same-timestamp multi-device samples to one row — acceptable for
  // single-user personal use. A multi-tenant/multi-device build should widen the unique key
  // to include source_device and revisit this dedup. Last write in iteration order wins.
  //
  // Normalize started_at to epoch ms before keying: iOS ISO8601DateFormatter with
  // .withInternetDateTime can produce "+00:00" or "-04:00" offset forms rather than "Z".
  // JS string comparison sees these as different; Postgres timestamptz normalizes them to
  // the same internal value — causing "cannot affect row a second time" on upsert.
  const seen = new Map<string, typeof rows[0]>()
  for (const row of rows) {
    const normTs = new Date(row.started_at).getTime()
    seen.set(`${row.metric_type}|${normTs}`, row)
  }
  const dedupedRows = Array.from(seen.values())

  // Use service role to bypass RLS for upsert (adminClient already defined above)
  const { error, count } = await adminClient
    .from('healthkit_metrics')
    .upsert(dedupedRows, {
      onConflict: 'user_id,metric_type,started_at',
      ignoreDuplicates: false,
      count: 'exact',
    })

  if (error) {
    console.error('Upsert error:', error)
    return json({ error: error.message }, 500)
  }

  return json({ inserted: count ?? dedupedRows.length })
})

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  })
}
