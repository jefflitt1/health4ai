-- Raw samples and daily rollups, ported from supabase/bootstrap/001.
--
-- Differences from the Supabase schema: user_id references people(id) instead of auth.users, and
-- there are no grants, row-level security policies or anon/authenticated/service_role roles. Only
-- this Deployment's functions and the Owner's own connection string reach these tables.
-- Column names and keys are unchanged, because the Python MCP server queries them as they are.

CREATE TABLE healthkit_metrics (
  id            uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id       uuid        NOT NULL REFERENCES people(id) ON DELETE CASCADE,
  metric_type   text        NOT NULL,
  value         float8,
  unit          text,
  -- NOT NULL DEFAULT '': source_device is part of the unique key, and a NULL member would make
  -- the constraint stop deduplicating.
  source_device text        NOT NULL DEFAULT '',
  started_at    timestamptz NOT NULL,
  ended_at      timestamptz,
  metadata      jsonb,
  synced_at     timestamptz NOT NULL DEFAULT now(),
  -- source_device is in the key: an Apple Watch and an Oura Ring recording the same instant are
  -- two samples, not one.
  CONSTRAINT healthkit_metrics_user_metric_device_started_key
    UNIQUE (user_id, metric_type, source_device, started_at)
);

CREATE INDEX healthkit_metrics_user_time_idx
  ON healthkit_metrics (user_id, started_at DESC);
CREATE INDEX healthkit_metrics_user_type_time_idx
  ON healthkit_metrics (user_id, metric_type, started_at DESC);
CREATE INDEX healthkit_metrics_metadata_idx
  ON healthkit_metrics USING gin (metadata);

-- Nothing writes this table yet: the MCP server aggregates days from raw samples when no summary
-- exists. It ships anyway because the MCP server queries it and fails if the table is missing.
CREATE TABLE healthkit_daily_summaries (
  id            uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id       uuid        NOT NULL REFERENCES people(id) ON DELETE CASCADE,
  metric_type   text        NOT NULL,
  summary_date  date        NOT NULL,
  avg_value     float8,
  min_value     float8,
  max_value     float8,
  sum_value     float8,
  sample_count  integer,
  -- NOT NULL because unit is part of the unique key below.
  unit          text        NOT NULL DEFAULT '',
  created_at    timestamptz NOT NULL DEFAULT now(),
  summarized_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT healthkit_daily_summaries_user_metric_date_key
    UNIQUE (user_id, metric_type, summary_date, unit)
);

CREATE INDEX healthkit_daily_summaries_user_date_idx
  ON healthkit_daily_summaries (user_id, summary_date DESC);
