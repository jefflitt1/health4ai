# health4.ai v2 — Product Requirements Document

**Status:** Planning  
**Based on:** v1 multi-tenant hosted tier (commit ad749aa, 2026-06-19)  
**Owner:** JGLV  

---

## Context

v1 shipped a complete hosted-tier onboarding system: setup code exchange, dual credentials (sync_token + mcp_api_key), multi-tenant Supabase RLS, iOS onboarding UI, and HTTP MCP transport. Users can register, sync HealthKit data, and have their AI query it.

v2 closes the security and infrastructure gaps required before open public launch.

---

## v2 Goals

1. **Security hardening** — tokens hashed at rest, rate limiting on registration
2. **Domain decoupling** — Supabase project ref removed from iOS binary
3. **Public MCP endpoint** — `mcp.health4.ai` live for external AI users
4. **iOS polish** — timer cleanup, JWT clear on mode switch

---

## Features

### F1 — Token Hashing at Rest
**Priority:** P0 (security)  
**Effort:** 4 hours

Store SHA-256 hashes of credentials in `healthkit_api_keys` instead of plaintext. A DB breach currently yields usable tokens.

**Scope:**
- Migration: rename `sync_token` → `sync_token_hash`, `mcp_api_key` → `mcp_api_key_hash`; populate hashes for existing rows
- `health4-register/index.ts` `/register`: hash before insert; return plaintext once to caller, never store it
- `health4-register/index.ts` `/validate`: hash incoming token before lookup
- `health4-register/index.ts` `/revoke`: hash before lookup
- `healthkit-ingest/index.ts`: hash `h4_sk_...` bearer before lookup
- `mcp-server/main.py` middleware: hash `h4_mk_...` before DB lookup

**Acceptance criteria:**
- `SELECT sync_token_hash FROM healthkit_api_keys` returns only SHA-256 hex strings (64 chars)
- `/validate` succeeds with plaintext token in Bearer header
- `/validate` fails with a hash directly in Bearer header

---

### F2 — Registration Rate Limiting
**Priority:** P0 (abuse prevention)  
**Effort:** 2 hours

No IP-based rate limiting today — a bot could exhaust Supabase auth user quota before open signup.

**Scope:**
- `health4-register/index.ts` `/setup` route: check `healthkit_setup_codes` for count of codes created from same IP in last 10 minutes; reject with 429 if > 5
- Use `request.headers.get('x-real-ip') ?? request.headers.get('cf-connecting-ip')` for IP (Supabase Edge Functions run behind Cloudflare)
- Add `created_from_ip TEXT` column to `healthkit_setup_codes` (migration 003)

**Acceptance criteria:**
- 6th `/setup` request from same IP within 10 minutes → HTTP 429 `{"error": "Too many requests"}`
- Different IP gets fresh quota

---

### F3 — `api.health4.ai` Cloudflare Proxy
**Priority:** P1 (operational resilience)  
**Effort:** 1 day

iOS binary hardcodes `donnmhbwhpjlmpnwgdqr.supabase.co`. Swapping Supabase projects would require an App Store release.

**Scope:**
- Cloudflare Worker at `api.health4.ai` proxying two paths:
  - `api.health4.ai/ingest` → `donnmhbwhpjlmpnwgdqr.supabase.co/functions/v1/healthkit-ingest`
  - `api.health4.ai/register/*` → `donnmhbwhpjlmpnwgdqr.supabase.co/functions/v1/health4-register/*`
- Worker passes all headers unchanged (especially `Authorization`, `Content-Type`)
- DNS: `api` CNAME in Cloudflare zone for `health4.ai`
- `ios/Health4AI/SyncState.swift`: update `hostedIngestURL` and `hostedAPIBase` to use `api.health4.ai`

**Acceptance criteria:**
- `curl -X POST https://api.health4.ai/register/setup` returns same response as hitting Supabase directly
- Changing `Worker` variable to a different project URL requires zero iOS changes

---

### F4 — `mcp.health4.ai` on Fly.io
**Priority:** P1 (product completeness)  
**Effort:** 1 day

HTTP MCP transport is implemented but not deployed. External users have no public endpoint to point their AI at.

**Scope:**
- `Dockerfile` at `mcp-server/Dockerfile`: Python 3.12-slim, install requirements.txt, `CMD ["python", "main.py", "--transport", "http", "--port", "8080"]`
- `fly.toml` at `mcp-server/fly.toml`: app name `health4ai-mcp`, region `iad`, `[[services]]` port 8080, health check `GET /`
- Fly.io secrets: `SUPABASE_URL`, `SUPABASE_SERVICE_KEY`, `MCP_AUTH_ENABLED=true` (no `DEFAULT_USER_ID` in prod)
- Add `GET /` health route in `main.py` that returns `{"status": "ok"}` — required for Fly health check
- DNS: `mcp` CNAME → `health4ai-mcp.fly.dev` in Cloudflare zone for `health4.ai`
- Update `web/src/pages/how-it-works.astro`: replace amber warning card about MCP setup with actual endpoint URL `mcp.health4.ai`

**Acceptance criteria:**
- `curl https://mcp.health4.ai/` → `{"status": "ok"}`
- Claude Desktop config pointing at `mcp.health4.ai` with `Authorization: Bearer h4_mk_...` returns health data for that user

---

### F5 — iOS: Clear JWT on Hosted Mode Switch
**Priority:** P2 (correctness)  
**Effort:** 30 minutes

When a user completes hosted onboarding, `connectionType` is set to `.hosted` but any existing Supabase JWT remains in Keychain. On reconnect the wrong auth path could trigger.

**Scope:**
- `ios/Health4AI/OnboardingView.swift` `validateToken()`: after `authManager.saveHostedSyncToken(token)` call `authManager.signOut()` to clear stale JWT
- `ios/Health4AI/ConnectionView.swift` `revokeHostedAccess()`: after revoke succeeds and `connectionType` resets to `.supabase`, set `syncState.isAuthenticated = false` (already done) — confirm no hosted token leaks back

**Acceptance criteria:**
- After completing hosted onboarding, `authManager.currentToken` is nil
- `authManager.isSignedIn` remains true (hostedSyncToken is set)

---

### F6 — CountdownView Timer Cancellation
**Priority:** P2 (resource hygiene)  
**Effort:** 30 minutes

`CountdownView` in `OnboardingView.swift` uses recursive `DispatchQueue.asyncAfter`. If the user navigates away mid-countdown the timer keeps firing.

**Scope:**
- Replace `DispatchQueue.asyncAfter` with `@State private var timer: Timer?`
- Start: `timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in ... }`
- Cancel: `.onDisappear { timer?.invalidate(); timer = nil }`

**Acceptance criteria:**
- Navigating away from the setup code screen while countdown is active does not produce timer callbacks after the view disappears

---

## Implementation Order

| Sprint | Features | Gate |
|--------|----------|------|
| 1 | F1 (token hashing) + F2 (rate limiting) | Security review before any features go to TestFlight |
| 2 | F3 (CF proxy) + F5 (JWT clear) + F6 (timer) | Regression test on iPad iOS 26.4.2 |
| 3 | F4 (Fly.io MCP deploy) | E2E test: setup → sync → AI query via `mcp.health4.ai` |

---

## Out of Scope for v2

- Stripe billing / usage metering
- User dashboard (web portal to view data, manage tokens)
- Android / watchOS
- Push notifications on sync failure
- Self-hosted onboarding improvements
