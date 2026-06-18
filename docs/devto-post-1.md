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
iPhone (HKObserverQuery) -> Supabase Edge Function -> healthkit schema -> FastMCP server -> Claude Code
```

The iOS app registers `HKObserverQuery` observers for every HealthKit metric type. When Apple Health receives new data (a completed workout, a new HRV reading, a sleep session from Oura), the observer fires and queues a sync. `BGTaskScheduler` handles periodic background delivery. On first launch, a bulk backfill exports your entire HealthKit history.

Data lands in a long/EAV schema in Supabase: one row per `HKSample`, with `metric_type`, `value`, `unit`, `started_at`, `ended_at`, `source_device`, and a `metadata` JSONB column for workout-specific fields. New metric types never require a schema migration.

The MCP server is a Python FastMCP process running locally on your machine. It reads from Supabase using the service role key (server-side only, never in the iOS app) and exposes 8 tools that Claude Code can call.

---

## Step-by-step setup

### 1. Clone the repo

```bash
git clone https://github.com/jefflitt1/health4ai.git
cd health4ai
```

### 2. Run the Supabase migration

You need a Supabase project. The free tier works fine for personal use.

```bash
supabase link --project-ref your-project-ref
supabase db push
```

Or apply the migrations manually from `supabase/migrations/` if you prefer. The main migration creates the `healthkit` schema, the `healthkit_metrics` table, RLS policies, and a few views for sleep and biometrics.

### 3. Install the iOS app

TestFlight link: **TBD** (the app is in TestFlight; public link coming soon).

Open it, sign in with your Supabase URL and credentials, and tap **Start Sync**. The first-launch backfill runs in the background and can take a few minutes depending on how much Health data you have. My backfill was 5.6 million rows.

### 4. Configure the MCP server

Copy the example env file:

```bash
cp mcp-server/.env.example mcp-server/.env
```

Fill in your values:

```env
SUPABASE_URL=https://your-project.supabase.co
SUPABASE_SERVICE_ROLE_KEY=your_service_role_key_here
HEALTHKIT_USER_ID=your_supabase_user_id_here
```

Get `HEALTHKIT_USER_ID` from the Supabase dashboard under Authentication > Users. It's the UUID of the account you used to sign into the iOS app.

Install Python dependencies:

```bash
cd mcp-server
python -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

### 5. Add it to Claude Code

Open `~/.claude/claude_desktop_config.json` (create it if it doesn't exist) and add:

```json
{
  "mcpServers": {
    "healthkit-bridge": {
      "command": "/path/to/health4ai/mcp-server/.venv/bin/python",
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

Restart Claude Code. Run `/mcp` to confirm the server shows up. You should see `healthkit-bridge` with 8 tools listed.

---

## What you can ask Claude

Here are 6 prompts that work well, along with which tool they trigger and what the response looks like.

**"How did I sleep this week?"**
Triggers `get_sleep`. Returns per-night breakdown with Core, Deep, and REM stage durations. Pulls from Oura Ring records in Apple Health if you have one (de-duplicates from Apple Watch to avoid double-counting).

**"Is my HRV trending up or down this month?"**
Triggers `get_hrv_trend`. Returns daily SDNN averages, a 7-day rolling comparison, and a direction flag: improving, declining, or stable.

**"Give me a full health summary for the last 14 days."**
Triggers `get_health_summary`. Returns average steps, average HRV, resting heart rate, sleep record count, and workout count and types.

**"What does yesterday look like?"**
Triggers `get_daily_snapshot`. Returns everything recorded that day: steps, active energy, resting HR, HRV, weight, any workouts, sleep records, and the full list of metric types present.

**"List my workouts from the last 30 days."**
Triggers `get_workouts`. Returns each workout with type, duration, distance, and calories burned.

**"Show me my resting heart rate trend over the past 2 years."**
Triggers `get_long_term_trend`. For windows beyond 180 days, the tool transparently switches from raw samples to pre-aggregated daily summaries, then monthly buckets. So a 2-year query is fast and complete.

---

## Self-host for free or use hosted

Self-hosting is free: your Supabase free tier, your Xcode build, your data. Nothing leaves your infrastructure. The hosted version (in development) will skip the Supabase and Xcode setup entirely. Install the App Store app, create an account, paste one JSON config block, and you're querying.

---

## GitHub

The full source is at [https://github.com/jefflitt1/health4ai](https://github.com/jefflitt1/health4ai). MIT licensed, PRs welcome.

If you set it up and run into anything, open an issue. The main thing still pending is the public TestFlight link and the hosted tier. Everything else is working.
