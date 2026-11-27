-- Indexed single-night read of the nightly sleep summary.
--
-- WHY: v_healthkit_sleep_nightly references its sleep_candidates CTE twice, so Postgres
-- materializes it across the whole table and the (user_id, night_date) filters never push
-- down. `select ... from v_healthkit_sleep_nightly where user_id=$1 and night_date=$2`
-- exceeds the 8s authenticator statement_timeout (57014) on ~4.8M rows. This function
-- bounds the scan to one user and one local-time night on the existing
-- (user_id, metric_type, started_at DESC) index, then applies the view's own logic.
--
-- Equivalent to the view row for (p_user_id, p_night_date): night_date there is
--   date_trunc('day', (started_at AT TIME ZONE 'America/New_York') - interval '6 hours')::date
-- i.e. local wall time L with D+06:00 <= L < D+1+06:00. 06:00 local never falls in a DST gap
-- (02:00-03:00) or repeated hour (01:00-02:00), so both bounds convert to exactly one instant,
-- and every instant between them has wall time inside the half-open range.
-- The view definition is NOT changed. NOTE: the view's live definition (priority Oura=1 /
-- Apple Watch=2, sleep_source) is not in 004_sleep_nightly_view.sql; this function mirrors the
-- live one (pg_get_viewdef, verified 2026-11-25).
-- Rollback: DROP FUNCTION public.healthkit_sleep_for_night(uuid, date);

CREATE OR REPLACE FUNCTION public.healthkit_sleep_for_night(p_user_id uuid, p_night_date date)
RETURNS TABLE(sleep_hours numeric, deep_minutes numeric, rem_minutes numeric, sleep_source text)
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
  WITH candidates AS (
    SELECT
      CASE
        WHEN m.source_device ILIKE '%Oura%' THEN 1
        WHEN m.source_device ILIKE '%Apple Watch%' THEN 2
        ELSE 9
      END AS source_priority,
      m.source_device, m.value, m.started_at, m.ended_at
    FROM public.healthkit_metrics m
    WHERE m.metric_type = 'HKCategoryTypeIdentifierSleepAnalysis'
      AND m.user_id = p_user_id
      AND m.started_at >= (p_night_date + time '06:00') AT TIME ZONE 'America/New_York'
      AND m.started_at <  ((p_night_date + 1) + time '06:00') AT TIME ZONE 'America/New_York'
      AND m.value IN (3.0, 4.0, 5.0)
      AND m.ended_at IS NOT NULL
      AND (m.source_device ILIKE '%Oura%' OR m.source_device ILIKE '%Apple Watch%')
  ), best AS (
    SELECT min(source_priority) AS best_priority FROM candidates
  ), filtered AS (
    SELECT c.* FROM candidates c JOIN best b ON c.source_priority = b.best_priority
  )
  SELECT
    round(sum(extract(epoch FROM ended_at - started_at) / 3600.0), 2),
    round(sum(CASE WHEN value = 4.0 THEN extract(epoch FROM ended_at - started_at) / 60.0 ELSE 0 END), 1),
    round(sum(CASE WHEN value = 5.0 THEN extract(epoch FROM ended_at - started_at) / 60.0 ELSE 0 END), 1),
    min(source_device)
  FROM filtered
  HAVING count(*) > 0;
$$;

REVOKE ALL ON FUNCTION public.healthkit_sleep_for_night(uuid, date) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.healthkit_sleep_for_night(uuid, date) TO service_role;
