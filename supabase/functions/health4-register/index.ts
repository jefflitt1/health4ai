// health4.ai — Registration Edge Function
// Routes:
//   POST /health4-register/setup    → generate setup code (called by iOS app)
//   POST /health4-register/register → exchange setup code for tokens (called by AI via MCP)
//   GET  /health4-register/validate → validate sync_token (called by iOS app after paste)
//   POST /health4-register/revoke   → revoke sync_token (called by iOS settings)

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const SUPABASE_URL              = Deno.env.get('SUPABASE_URL')!
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!

const admin = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY)

Deno.serve(async (req: Request) => {
  const url  = new URL(req.url)
  const path = url.pathname.replace(/^\/health4-register/, '')

  // --- /setup -----------------------------------------------------------
  if (req.method === 'POST' && path === '/setup') {
    // F2: IP-based rate limiting (5 codes per IP per 10 minutes)
    const ip = req.headers.get('cf-connecting-ip')
           ?? req.headers.get('x-real-ip')
           ?? 'unknown'

    if (ip !== 'unknown') {
      const cutoff = new Date(Date.now() - 10 * 60 * 1000).toISOString()
      const { count } = await admin
        .from('healthkit_setup_codes')
        .select('*', { count: 'exact', head: true })
        .eq('created_from_ip', ip)
        .gte('created_at', cutoff)

      if ((count ?? 0) >= 5) {
        return json({ error: 'Too many requests. Try again in 10 minutes.' }, 429)
      }
    }

    const code       = generateCode()
    const expires_at = new Date(Date.now() + 30 * 60 * 1000).toISOString() // 30 min

    const { error } = await admin
      .from('healthkit_setup_codes')
      .insert({ code, expires_at, created_from_ip: ip })

    if (error) return json({ error: 'Failed to create setup code' }, 500)

    return json({ code, expires_at, instructions: copyablePrompt(code) })
  }

  // --- /register --------------------------------------------------------
  if (req.method === 'POST' && path === '/register') {
    let body: { setup_code?: string }
    try { body = await req.json() } catch { return json({ error: 'Invalid JSON' }, 400) }

    const { setup_code } = body
    if (!setup_code) return json({ error: 'setup_code is required' }, 400)

    // Validate and consume the setup code
    const { data: codeRow, error: codeErr } = await admin
      .from('healthkit_setup_codes')
      .select('*')
      .eq('code', setup_code)
      .eq('used', false)
      .gt('expires_at', new Date().toISOString())
      .single()

    if (codeErr || !codeRow) return json({ error: 'Invalid or expired setup code' }, 400)

    // Mark code used (before creating user — prevents replay even if user creation fails)
    await admin
      .from('healthkit_setup_codes')
      .update({ used: true })
      .eq('code', setup_code)

    // Create a synthetic Supabase auth user for this device
    const syntheticEmail = `${crypto.randomUUID()}@device.health4.ai`
    const { data: userResult, error: createErr } = await admin.auth.admin.createUser({
      email:         syntheticEmail,
      password:      crypto.randomUUID() + crypto.randomUUID(), // never shown to user
      email_confirm: true,
    })

    if (createErr || !userResult.user) {
      return json({ error: 'Failed to create user account' }, 500)
    }

    const userId = userResult.user.id

    // Generate plaintext tokens — returned to caller once, never stored
    const syncToken = 'h4_sk_' + randomHex(32)
    const mcpApiKey = 'h4_mk_' + randomHex(32)

    // F1: store SHA-256 hashes only
    const { error: keyErr } = await admin
      .from('healthkit_api_keys')
      .insert({
        user_id:          userId,
        sync_token_hash:  await sha256hex(syncToken),
        mcp_api_key_hash: await sha256hex(mcpApiKey),
      })

    if (keyErr) return json({ error: 'Failed to create API keys' }, 500)

    return json({
      user_id:     userId,
      sync_token:  syncToken,
      mcp_api_key: mcpApiKey,
      next_steps: [
        `Paste this sync token into the health4.ai app: ${syncToken}`,
        `Add health4.ai MCP to your AI with key: ${mcpApiKey} at https://mcp.health4.ai`,
      ],
    })
  }

  // --- /validate --------------------------------------------------------
  if (req.method === 'GET' && path === '/validate') {
    const token = url.searchParams.get('token')
    if (!token) return json({ error: 'token is required' }, 400)

    // F1: hash before lookup
    const { data, error } = await admin
      .from('healthkit_api_keys')
      .select('user_id, last_sync')
      .eq('sync_token_hash', await sha256hex(token))
      .eq('revoked', false)
      .single()

    if (error || !data) return json({ valid: false }, 401)
    return json({ valid: true, user_id: data.user_id, last_sync: data.last_sync })
  }

  // --- /revoke ----------------------------------------------------------
  if (req.method === 'POST' && path === '/revoke') {
    let body: { sync_token?: string }
    try { body = await req.json() } catch { return json({ error: 'Invalid JSON' }, 400) }

    const token = body.sync_token
    if (!token?.startsWith('h4_sk_')) return json({ error: 'Invalid token' }, 400)

    // F1: hash before lookup
    const { error } = await admin
      .from('healthkit_api_keys')
      .update({ revoked: true })
      .eq('sync_token_hash', await sha256hex(token))

    if (error) return json({ error: 'Revocation failed' }, 500)
    return json({ revoked: true })
  }

  return json({ error: 'Not found' }, 404)
})

// ---------------------------------------------------------------------------

async function sha256hex(text: string): Promise<string> {
  const buf = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(text))
  return Array.from(new Uint8Array(buf)).map(b => b.toString(16).padStart(2, '0')).join('')
}

function generateCode(): string {
  const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789' // no O/0/I/1 (ambiguous)
  const rand = (n: number) => Array.from(crypto.getRandomValues(new Uint8Array(n)))
    .map(b => chars[b % chars.length]).join('')
  return `H4-${rand(4)}-${rand(4)}`
}

function randomHex(bytes: number): string {
  const arr = new Uint8Array(bytes)
  crypto.getRandomValues(arr)
  return Array.from(arr).map(b => b.toString(16).padStart(2, '0')).join('')
}

function copyablePrompt(code: string): string {
  return `I just downloaded health4.ai. Please set up my health data table. My setup code is: ${code}`
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      'Content-Type': 'application/json',
      'Access-Control-Allow-Origin': '*',
    },
  })
}
