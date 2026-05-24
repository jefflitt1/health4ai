# HealthKit Bridge — Setup Guide

## Step 1: Run the Supabase Migration

DDL must go through the Supabase Management API. The `exec_sql` RPC is not
available on this project. Get a Personal Access Token from
https://supabase.com/dashboard/account/tokens (NOT the service role key).

```bash
export SUPABASE_PAT="sbp_your_personal_access_token"
PROJECT_REF="donnmhbwhpjlmpnwgdqr"

curl -X POST \
  "https://api.supabase.com/v1/projects/$PROJECT_REF/database/query" \
  -H "Authorization: Bearer $SUPABASE_PAT" \
  -H "Content-Type: application/json" \
  -H "User-Agent: healthkit-bridge-setup" \
  -d @- < <(jq -Rs '{query: .}' < ../supabase/migrations/001_healthkit_schema.sql)
```

Then in Supabase Dashboard > Settings > API > Exposed Schemas, add `healthkit`
(required — the MCP server and Edge Function both target the `healthkit` schema
and PostgREST will 404 until it is exposed).

## Step 2: Deploy the Edge Function

```bash
# Install Supabase CLI if needed: brew install supabase/tap/supabase
cd supabase
supabase functions deploy healthkit-ingest --project-ref donnmhbwhpjlmpnwgdqr
```

## Step 3: Set up the MCP Server

```bash
cd mcp-server
cp .env.example .env
# Edit .env — add SUPABASE_SERVICE_ROLE_KEY and HEALTHKIT_USER_ID

pip install -r requirements.txt
python main.py  # test it runs
```

## Step 4: Add to Claude Code MCP config

Add to `~/.claude/claude_desktop_config.json` (or your Claude Code MCP config):

```json
{
  "mcpServers": {
    "healthkit-bridge": {
      "command": "python",
      "args": ["/Users/jgl/ventures/healthkit-bridge/mcp-server/main.py"],
      "env": {
        "SUPABASE_URL": "https://donnmhbwhpjlmpnwgdqr.supabase.co",
        "SUPABASE_SERVICE_ROLE_KEY": "your_key_here",
        "HEALTHKIT_USER_ID": "your_user_id_here"
      }
    }
  }
}
```

## Step 5: iOS App

1. Open `ios/HealthKitBridge.xcodeproj` in Xcode
2. Set your Team in Signing & Capabilities
3. Change bundle ID if desired (default: `com.healthkitbridge.app`)
4. Build and run on your iPhone (or distribute via TestFlight)
5. Sign in with Supabase email/password
6. Tap "Run Backfill" to import all historical data
7. Background sync will run automatically every hour

## Supabase Auth Setup

Create a user in Supabase Dashboard > Authentication > Users (or via the iOS app sign-up flow).
Copy the user's UUID — this is your `HEALTHKIT_USER_ID` for the MCP server.

## Testing the MCP

Once data is flowing, in Claude Code:
- "How was my sleep last week?"
- "What's my HRV trend over the last month?"
- "How many workouts did I do this month?"
- "Give me a snapshot of yesterday's health data"
