-- Jeff's HealthKit freshness monitor orders by synced_at. The existing indexes
-- only cover started_at, so PostgREST sorts old core rows and hits its 8-second
-- statement timeout. Run on production outside a transaction; CONCURRENTLY
-- allows ingestion to continue. A failed concurrent build can leave an invalid
-- same-name index; fail on a retry rather than silently skipping it. Verify
-- pg_index.indisvalid and the definition, then EXPLAIN the monitor query.
CREATE INDEX CONCURRENTLY healthkit_metrics_user_synced_idx
  ON public.healthkit_metrics (user_id, synced_at DESC);
