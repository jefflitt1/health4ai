# HealthKit Bridge (JGLV-008)

The HealthKit bridge for AI-native workflows. An invisible infrastructure layer
that pipes Apple Health data from an iPhone into a database and exposes it as
clean tool calls for LLM clients like Claude Code.

Not a consumer app. No dashboards, no charts. One settings screen and a sync
engine. The MCP server is the product.

## Why this exists

Apple HealthKit has no server-side API — all access goes through an on-device
iOS app. The existing option (Health Auto Export) is a closed-source $30
consumer tool whose "MCP server" only works over same-WiFi TCP. This is the
open, developer-first replacement: your health data available to your AI agent
as a tool call, from anywhere.

## Architecture

```
iPhone HealthKit (all metrics, raw time-series)
  → iOS app (bulk backfill + background + workout triggers + foreground sync)
  → HTTP POST + Supabase JWT (Bearer)
  → Supabase Edge Function (validates JWT → upserts)
  → healthkit.metrics table (long/EAV schema, multi-tenant, RLS)
  → FastMCP server (service-role, server-side only)
  → Claude Code
```

## Components

| Dir | What | Stack |
|-----|------|-------|
| `ios/` | iOS app — HealthKit sync engine, settings UI, Supabase auth | Swift / SwiftUI, iOS 17+ |
| `supabase/migrations/` | `healthkit` schema, RLS, indexes | SQL |
| `supabase/functions/healthkit-ingest/` | Ingest Edge Function | Deno / TypeScript |
| `mcp-server/` | MCP server — 6 tools over Supabase | Python / FastMCP |

## Design decisions (locked 2026-05-20)

- **Data model:** long/EAV — one row per HKSample. New metrics never need migrations.
- **Granularity:** raw time-series, every sample point and sleep-phase segment.
- **Backfill:** first-launch bulk export of all historical HealthKit data.
- **Sync:** BGTaskScheduler + HKObserverQuery + workout-completion + foreground.
- **Metrics:** all HKSampleTypes enumerated dynamically, not a hardcoded list.
- **Multi-tenant:** `user_id` on every row from day one (Supabase Auth).
- **No middleware:** iOS app POSTs directly to the Edge Function (no n8n).

## Setup

See [docs/SETUP.md](docs/SETUP.md). Four steps: run migration → deploy Edge
Function → build iOS app in Xcode → configure MCP server.

## Security

- Service role key is **server-side only** (MCP server on Mac Studio). Never in the iOS app.
- iOS app authenticates with per-user Supabase JWT, stored in Keychain.
- `user_id` is derived from the validated JWT in the Edge Function — never trusted from the request body.
- RLS scopes every user to their own rows.

## Status

Scaffold complete. Pending: Supabase migration run, Edge Function deploy,
Xcode build + TestFlight, MCP config. See MANIFEST.md (JGLV-008).
