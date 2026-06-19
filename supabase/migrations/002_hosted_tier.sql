-- health4.ai hosted tier — setup codes and API keys
-- Run via: Supabase Management API POST /v1/projects/{ref}/database/query
-- Applied: 2026-06-19

CREATE TABLE IF NOT EXISTS public.healthkit_setup_codes (
  code        TEXT        NOT NULL PRIMARY KEY,
  expires_at  TIMESTAMPTZ NOT NULL,
  used        BOOLEAN     NOT NULL DEFAULT false,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.healthkit_api_keys (
  id           UUID        NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id      UUID        NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  sync_token   TEXT        NOT NULL UNIQUE,  -- h4_sk_... (iOS credential)
  mcp_api_key  TEXT        NOT NULL UNIQUE,  -- h4_mk_... (AI/MCP credential)
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_sync    TIMESTAMPTZ,
  revoked      BOOLEAN     NOT NULL DEFAULT false
);

CREATE INDEX IF NOT EXISTS idx_api_keys_sync_token
  ON public.healthkit_api_keys (sync_token)
  WHERE NOT revoked;

CREATE INDEX IF NOT EXISTS idx_api_keys_mcp_key
  ON public.healthkit_api_keys (mcp_api_key)
  WHERE NOT revoked;

-- These tables are accessed by Edge Functions via service_role only.
-- RLS is enabled but no user-facing policies are needed.
ALTER TABLE public.healthkit_setup_codes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.healthkit_api_keys    ENABLE ROW LEVEL SECURITY;
