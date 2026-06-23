-- health4ai — HealthKit schema migration
-- Run against your Supabase project via the SQL Editor or Management API.

CREATE SCHEMA IF NOT EXISTS healthkit;

-- Grant usage to PostgREST roles
GRANT USAGE ON SCHEMA healthkit TO anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA healthkit
    GRANT ALL ON TABLES TO service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA healthkit
    GRANT SELECT ON TABLES TO authenticated;

-- Main time-series table (long/EAV — one row per sample)
CREATE TABLE healthkit.metrics (
    id           uuid        DEFAULT gen_random_uuid() PRIMARY KEY,
    user_id      uuid        NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    metric_type  text        NOT NULL,
    value        float8,
    unit         text,
    source_device text,
    started_at   timestamptz NOT NULL,
    ended_at     timestamptz,
    metadata     jsonb,
    synced_at    timestamptz DEFAULT now() NOT NULL
);

-- Dedup key for upsert (user + type + start time is the natural key)
CREATE UNIQUE INDEX metrics_upsert_key
    ON healthkit.metrics (user_id, metric_type, started_at);

-- Primary query patterns
CREATE INDEX metrics_user_time_idx
    ON healthkit.metrics (user_id, started_at DESC);

CREATE INDEX metrics_user_type_time_idx
    ON healthkit.metrics (user_id, metric_type, started_at DESC);

-- JSONB index for metadata queries (sleep stages, workout types)
CREATE INDEX metrics_metadata_idx
    ON healthkit.metrics USING gin(metadata);

-- RLS: users see only their own data
ALTER TABLE healthkit.metrics ENABLE ROW LEVEL SECURITY;

CREATE POLICY "users_own_data"
    ON healthkit.metrics
    FOR ALL
    USING (auth.uid() = user_id);

-- NOTE: service_role bypasses RLS unconditionally in Supabase. The Edge Function
-- upserts as service_role, so no explicit bypass policy is needed (adding one
-- would be misleading — do not add it).

-- Expose schema to PostgREST
-- NOTE: after running this migration, add 'healthkit' to the
-- exposed_schemas list in Supabase project API settings
COMMENT ON SCHEMA healthkit IS 'HealthKit Bridge — personal health time-series data';
COMMENT ON TABLE healthkit.metrics IS 'Raw HealthKit samples. One row per HKSample. Long/EAV schema.';
