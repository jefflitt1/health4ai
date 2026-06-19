// health4.ai — Registration Edge Function
// Routes:
//   POST /health4-register/setup    → generate setup code (called by iOS app)
//   POST /health4-register/register → exchange setup code for tokens (called by AI via MCP)
//   GET  /health4-register/validate → validate sync_token (called by iOS app after paste)

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const SUPABASE_URL              = Deno.env.get('SUPABASE_URL')!
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
const FUNCTION_SECRET           = Deno.env.get('HEALTH4_REGISTER_SECRET') ?? ''

const admin = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY)

Deno.serve(async (req: Request) => {
  const url  = new URL(req.url)
  const path = url.pathname.replace(/^\/health4-register/, '')

  // --- /setup -----------------------------------------------------------
  if (req.method === 'POST' && path === '/setup') {
    const code       = generateCode()
    const expires_at = new Date(Date.now() + 30 * 60 * 1000).toISOString() // 30 min

    const { error } = await admin
      .from('healthkit_setup_codes')
      .insert({ code, expires_at })

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

    // Mark code used
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

    // Generate tokens
    const syncToken  = 'h4_sk_' + randomHex(32)
    const mcpApiKey  = 'h4_mk_' + randomHex(32)

    const { error: keyErr } = await admin
      .from('healthkit_api_keys')
      .insert({
        user_id:     userId,
        sync_token:  syncToken,
        mcp_api_key: mcpApiKey,
      })

    if (keyErr) return json({ error: 'Failed to create API keys' }, 500)

    return json({
      user_id:     userId,
      sync_token:  syncToken,
      mcp_api_key: mcpApiKey,
      instructions: pasteInstructions(syncToken, mcpApiKey),
    })
  }

  // --- /validate --------------------------------------------------------
  if (req.method === 'GET' && path === '/validate') {
    const token = url.searchParams.get('token')
    if (!token) return json({ error: 'token is required' }, 400)

    const { data, error } = await admin
      .from('healthkit_api_keys')
      .select('user_id, last_sync')
      .eq('sync_token', token)
      .eq('revoked', false)
      .single()

    if (error || !data) return json({ valid: false }, 401)
    return json({ valid: true, user_id: data.user_id, last_sync: data.last_sync })
  }

  // --- /revoke ----------------------------------------------------------
  if (req.method === 'POST' && path === '/revoke') {
    const authHeader = req.headers.get('Authorization')
    const token = authHeader?.replace('Bearer ', '') ?? ''
    if (!token.startsWith('h4_sk_')) return json({ error: 'Invalid token' }, 400)

    const { error } = await admin
      .from('healthkit_api_keys')
      .update({ revoked: true })
      .eq('sync_token', token)

    if (error) return json({ error: 'Revocation failed' }, 500)
    return json({ revoked: true })
  }

  return json({ error: 'Not found' }, 404)
})

// ---------------------------------------------------------------------------

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

function pasteInstructions(syncToken: string, mcpApiKey: string): string {
  return [
    "Your health data table is ready.",
    "",
    "Step 1 — Open health4.ai on your phone and paste this sync token:",
    syncToken,
    "",
    "Step 2 — Add health4.ai to your AI (Claude Desktop example):",
    JSON.stringify({
      mcpServers: {
        "health4ai": {
          url: "https://mcp.health4.ai",
          transport: "http",
          headers: { Authorization: `Bearer ${mcpApiKey}` }
        }
      }
    }, null, 2),
    "",
    "Once you paste the sync token and tap Verify in the app, your health data will start syncing.",
    "Ask me anything about your health data once the first sync completes (usually a few minutes).",
  ].join('\n')
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
