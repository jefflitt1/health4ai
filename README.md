# health4.ai — Apple Health data for AI

[![MIT License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Python](https://img.shields.io/badge/python-3.11%2B-blue.svg)](mcp-server/)
[![iOS](https://img.shields.io/badge/iOS-17%2B-black.svg)](ios/)
[![MCP](https://img.shields.io/badge/MCP-FastMCP-green.svg)](mcp-server/)

Sync Apple HealthKit to Supabase. Query it from Claude Code, ChatGPT, Cursor, or n8n via MCP.

## Why it exists

- **Apple has no HealthKit server API.** All HealthKit access requires an on-device iOS app — there is no REST endpoint you can call from a server.
- **Health Auto Export only works on the same WiFi.** It exposes health data over local TCP, which means your AI agent can't reach it from a cloud runner or a remote session.
- **The claude.ai Apple Health connector doesn't reach Claude Code CLI.** The native connector in claude.ai web works only in that interface — not in Claude Code, Cursor, or any MCP client.

health4.ai is the open, developer-first fix: a native iOS app that pushes your HealthKit data to Supabase, plus a FastMCP server that exposes it as tool calls from anywhere.

## Quick start

**1. Clone the repo**

```bash
git clone https://github.com/jefflitt1/health4ai.git
cd health4ai
```

**2. Run the Supabase migration**

```bash
supabase db push
# or apply migrations manually from supabase/migrations/
```

**3. Install the iOS app**

Install via TestFlight: **TBD** (link will be added when the app is publicly available)

Open the app, sign in with your Supabase credentials, and tap **Start Sync**. A bulk backfill of all your HealthKit history runs on first launch.

**4. Configure `.env`**

```bash
cp mcp-server/.env.example mcp-server/.env
```

Edit `mcp-server/.env`:

```env
SUPABASE_URL=https://your-project.supabase.co
SUPABASE_SERVICE_ROLE_KEY=your_service_role_key_here
HEALTHKIT_USER_ID=your_supabase_user_id_here
```

**5. Add to `claude_desktop_config.json`**

```json
{
  "mcpServers": {
    "healthkit-bridge": {
      "command": "python",
      "args": ["/path/to/health4ai/mcp-server/main.py"],
      "env": {
        "SUPABASE_URL": "https://your-project.supabase.co",
        "SUPABASE_SERVICE_ROLE_KEY": "your_service_role_key_here",
        "HEALTHKIT_USER_ID": "your_supabase_user_id_here"
      }
    }
  }
}
```

Restart Claude Code. You're done.

## MCP tools

| Tool | Description | Example prompt |
|------|-------------|----------------|
| `get_health_summary` | Overview of key metrics for the past N days: steps, HRV, resting HR, sleep, workouts | "Give me a health summary for the last 7 days" |
| `get_sleep` | Per-night sleep breakdown with stage durations (REM, Deep, Core) from Oura Ring | "How did I sleep this week?" |
| `get_hrv_trend` | Daily HRV (SDNN) with 7-day rolling comparison and trend direction | "Is my HRV trending up or down this month?" |
| `get_daily_snapshot` | Everything recorded for a specific date: steps, sleep, workouts, all metrics | "What does yesterday look like?" |
| `get_workouts` | Recent workouts with type, duration, distance, and calories | "List my workouts from the last 30 days" |
| `query_metric` | Raw time-series for any HealthKit metric type by identifier | "Show me my VO2 max readings for the last 90 days" |
| `get_long_term_trend` | Monthly aggregates for any metric over years; tier-aware (merges raw + summary) | "What's my resting HR trend over the past 2 years?" |
| `get_coaching_brief` | Pre-session coaching brief: recovery status, sleep quality, training load, fitness markers | "Pull up my coaching brief for today" |

All tools accept an optional `user_id` parameter for multi-tenant deployments.

## Architecture

```
iPhone (HKObserverQuery) → Supabase Edge Function → healthkit schema → FastMCP server → Claude Code
```

The iOS app uses `HKObserverQuery` for background delivery and `BGTaskScheduler` for periodic sync. Data lands in a long/EAV schema (`healthkit_metrics` table) with one row per `HKSample`. The MCP server reads directly from Supabase using the service role key — server-side only, never exposed to the iOS app.

For queries within the last 180 days, tools return raw samples. Beyond 180 days, they transparently switch to pre-aggregated daily summaries (`healthkit_daily_summaries`), so long-term trend queries stay fast.

## Repo structure

```
health4ai/
├── ios/                        # Swift/SwiftUI iOS app (iOS 17+)
│   └── Health4AI/              # HealthKit sync engine, auth, settings
├── supabase/
│   ├── migrations/             # healthkit schema, RLS, indexes, views
│   └── functions/
│       └── healthkit-ingest/   # Deno edge function (JWT validation + upsert)
├── mcp-server/
│   ├── main.py                 # FastMCP server entry point
│   ├── tools.py                # All 8 tool implementations
│   └── .env.example            # Required environment variables
├── scripts/
│   ├── import_health_export.py # One-time XML backfill from Apple Health export
│   └── summarize_historical.py # Backfill daily summaries table
├── web/                        # health4.ai marketing site (Astro)
└── docs/
    └── SETUP.md                # Detailed setup guide
```

## Self-host vs hosted

Self-host is free: run the Supabase migration on your own project, build the iOS app in Xcode, and point the MCP server at your database. The hosted version (coming) will skip the Supabase and Xcode setup — install the app from the App Store, sign up, and paste one config block.

## Contributing

MIT licensed. PRs welcome. See CONTRIBUTING.md.

Open issues for bugs or feature requests. The main areas with room to grow: additional metric aggregations, multi-user dashboards, and Android support.

## License

MIT — see [LICENSE](LICENSE).
