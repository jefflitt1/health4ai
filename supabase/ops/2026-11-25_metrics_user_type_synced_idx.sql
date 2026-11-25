-- Daily HealthKit brief reads "newest synced_at for one metric" (order by synced_at desc limit 1,
-- per metric_type). The existing (user_id, synced_at DESC) index forces a filtered scan of
-- 645k+ rows (11.8s, > the 8s authenticator timeout). This index makes it a single index probe.
-- Run on production OUTSIDE a transaction (same precedent as 2026-10-30_metrics_sync_index.sql):
-- CONCURRENTLY takes SHARE UPDATE EXCLUSIVE, so ingestion keeps writing. The session must not be
-- subject to the 8s timeout (postgres role / SQL editor; the SET below covers it).
-- Verify afterwards: pg_index.indisvalid = true for this index. A failed build leaves an INVALID
-- same-name index; no IF NOT EXISTS (same as the 2026-10-30 precedent), so a retry fails loudly
-- instead of silently skipping it: DROP INDEX CONCURRENTLY the invalid one, then re-run.
-- Rollback: DROP INDEX CONCURRENTLY public.healthkit_metrics_user_type_synced_idx;
SET statement_timeout = 0;
CREATE INDEX CONCURRENTLY healthkit_metrics_user_type_synced_idx
  ON public.healthkit_metrics (user_id, metric_type, synced_at DESC);
