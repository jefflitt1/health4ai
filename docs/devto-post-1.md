# How to give Claude Code access to your Apple Health data

Apple has no HealthKit REST API. Claude's native Apple Health connector only works on claude.ai web, not Claude Code. Here's how to fix that.

---

## The constraint

Apple's privacy design is the core issue. HealthKit data never leaves your device through a server-side API. There's no endpoint you can call from a script, a cloud function, or an AI agent. All HealthKit access goes through an on-device iOS app that the user has explicitly granted permission.

That's actually good for privacy. But it creates a real problem if you want to query your health data from Claude Code, Cursor, or any MCP client running outside the claude.ai web interface.

The existing workarounds have limits. Health Auto Export is a solid app, but its MCP server works over local TCP. Your Claude Code session on a Mac Studio can't reach it if your phone is on a different network, or if you're on a VPN. The built-in Apple Health connector in claude.ai is great for the web UI but doesn't expose anything to Claude Code or any other MCP client.

The only real solution is to build your own sync layer: an iOS app that reads HealthKit and pushes to a database you control, plus an MCP server that Claude can talk to.

That's what health4.ai is.

---

## What health4.ai does

The architecture is straightforward:

```
iPhone (HKObserverQuery) → Your Postgres database → FastMCP server → Any AI
```

The iOS app registers `HKObserverQuery` observers for every HealthKit metric type. When Apple Health receives new data (a completed workout, a new HRV reading, a sleep session), the observer fires and queues a sync. `BGTaskScheduler` handles periodic background delivery. On first launch, a bulk backfill exports your entire HealthKit history — mine was around 5.6 million rows.

Data lands in a simple EAV schema: one row per `HKSample`, with `metric_type`, `value`, `unit`, `started_at`, `ended_at`, `source_device`, and a `metadata` JSONB column. New metric types never require a schema migration.

The MCP server is a Python FastMCP process running locally. It reads directly from Postgres (your credentials, your database) and exposes 11 tools that any MCP client can call.

**You own the data.** health4.ai never receives or stores your health data. It flows from your iPhone to your Postgres database — you choose the provider.

---

## Step-by-step setup

### 1. Clone the repo

```bash
git clone https://github.com/jefflitt1/health4ai.git
cd health4ai
```

### 2. Set up your Postgres database

Pick the backend that fits you and run the schema:

**Supabase (free tier works fine):**
```bash
psql "$DATABASE_URL" < web/public/schema.sql
```

**Neon (serverless Postgres):**
```bash
psql "$DATABASE_URL" < web/public/schema.sql
```

**Local Docker:**
```bash
docker run -d --name health4ai-postgres \
  -e POSTGRES_PASSWORD=yourpassword -p 5432:5432 postgres:16
psql "postgresql://postgres:yourpassword@localhost:5432/postgres" \
  < web/public/schema.sql
```

### 3. Install the iOS app

TestFlight link: **coming soon** — the app is in review. Sign in with your Postgres connection details and tap **Start Sync**.

### 4. Configure the MCP server

```bash
cp mcp-server/.env.example mcp-server/.env
```

Edit `mcp-server/.env`:

```env
DATABASE_URL=postgresql://...    # your Postgres connection string
HEALTHKIT_USER_ID=your_user_id   # any string to identify your data
```

Install dependencies:

```bash
cd mcp-server && pip install -r requirements.txt
```

### 5. Add it to Claude Code

```json
{
  "mcpServers": {
    "health4ai": {
      "command": "python",
      "args": ["/path/to/health4ai/mcp-server/main.py"],
      "env": {
        "DATABASE_URL": "postgresql://...",
        "HEALTHKIT_USER_ID": "your_user_id"
      }
    }
  }
}
```

Restart Claude Code. Run `/mcp` to confirm. You should see `health4ai` with 11 tools listed.

**Works with Cursor too** — same config block in `~/.cursor/mcp.json`.

**Fully local with Ollama:**
```bash
mcphost --model ollama/llama3.2 \
  --mcp-server "health4ai:python /path/to/health4ai/mcp-server/main.py"
```
Your data and the model both stay on-device. Nothing leaves your machine.

---

## What you can ask

Here are prompts that work well, along with which tool they trigger:

**"How did I sleep this week?"** → `get_sleep` — per-night breakdown with Core, Deep, and REM stage durations.

**"Is my HRV trending up or down this month?"** → `get_hrv_trend` — daily SDNN averages, 7-day rolling comparison, trend direction.

**"Give me a full health summary for the last 14 days."** → `get_health_summary` — steps, HRV, resting HR, sleep, workouts.

**"What does yesterday look like?"** → `get_daily_snapshot` — everything recorded that day.

**"Is 42ms HRV good or bad for me?"** → `get_metric_stats` — your personal baseline: min/max/mean, percentiles, good/poor-day thresholds.

**"Did my sleep improve after I started lifting?"** → `compare_periods` — compare any metric between two date ranges with delta, % change, and a plain-English verdict.

**"Show me my resting heart rate trend over the past 2 years."** → `get_long_term_trend` — transparently switches to pre-aggregated monthly buckets beyond 180 days, so it's fast and complete regardless of data volume.

---

## GitHub

[https://github.com/jefflitt1/health4ai](https://github.com/jefflitt1/health4ai) — MIT licensed. PRs welcome.

If you set it up and run into anything, open an issue. The main thing still pending is the public TestFlight link. Everything else is working.
