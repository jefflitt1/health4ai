# health4ai — Setup Guide

## Step 1: Set up your Postgres database

Run the schema against your chosen backend:

```bash
psql "$DATABASE_URL" < web/public/schema.sql
```

**Supabase:** get `DATABASE_URL` from Settings → Database → Connection string (URI).
**Neon:** get it from Connection Details.
**Local Docker:** `postgresql://postgres:yourpassword@localhost:5432/postgres`

If using Supabase and the schema needs to go through the Management API:

```bash
export SUPABASE_PAT="sbp_your_personal_access_token"
PROJECT_REF="your_project_ref"

curl -X POST \
  "https://api.supabase.com/v1/projects/$PROJECT_REF/database/query" \
  -H "Authorization: Bearer $SUPABASE_PAT" \
  -H "Content-Type: application/json" \
  -H "User-Agent: health4ai-setup" \
  -d @- < <(jq -Rs '{query: .}' < web/public/schema.sql)
```

## Step 2: Configure the MCP Server

```bash
cd mcp-server
cp .env.example .env
# Edit .env — add DATABASE_URL and HEALTHKIT_USER_ID

pip install -r requirements.txt
python main.py  # test it runs
```

## Step 3: Add to your AI client

**Claude Code / Claude Desktop** — add to `claude_desktop_config.json`:

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

**Cursor** — same block in `~/.cursor/mcp.json`.

**Ollama (fully local):**
```bash
mcphost --model ollama/llama3.2 \
  --mcp-server "health4ai:python /path/to/health4ai/mcp-server/main.py"
```

## Step 4: iOS App

1. Open `ios/Health4AI.xcodeproj` in Xcode
2. Set your Team in Signing & Capabilities
3. Build and run on your iPhone (iOS 17+)
4. Enter your database credentials and tap **Start Sync**

The first launch runs a full backfill of your HealthKit history — this can take a few minutes depending on data volume.

## Step 5: Verify

In your AI client, ask: *"Give me a health summary for the last 7 days."* You should get a response with steps, HRV, and sleep data.

Run `/mcp` in Claude Code to confirm the `health4ai` server is listed with its tools.
