-- The September invariant omitted min/max and tolerated tiny sum differences,
-- while health4ai_compact_metric_v2 updates a summary when any of sum, count,
-- min, or max differs. Keep the read-only mismatch check identical to that writer.
CREATE OR REPLACE FUNCTION public.health4ai_recompute_mismatches(
  p_user_id uuid, p_metric_type text, p_cutoff date,
  p_tz text DEFAULT 'America/New_York'
)
RETURNS TABLE(day date, unit text, raw_sum double precision, summary_sum double precision,
              raw_rows bigint, summary_samples integer)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $func$
  WITH raw AS (
    SELECT (started_at AT TIME ZONE p_tz)::date AS d, coalesce(unit, '') AS u,
           sum(value) AS s, count(*) AS c, min(value) AS mn, max(value) AS mx
    FROM public.healthkit_metrics
    WHERE user_id = p_user_id AND metric_type = p_metric_type
      AND started_at < (p_cutoff::timestamp AT TIME ZONE p_tz)
    GROUP BY 1, 2 HAVING bool_and(source_device = 'HealthKit (all sources)'))
  SELECT raw.d, raw.u, raw.s, s.sum_value, raw.c, s.sample_count
  FROM raw LEFT JOIN public.healthkit_daily_summaries s
    ON s.user_id = p_user_id AND s.metric_type = p_metric_type AND s.date = raw.d AND s.unit = raw.u
  WHERE s.id IS NULL
     OR s.sum_value IS DISTINCT FROM raw.s
     OR s.sample_count IS DISTINCT FROM raw.c
     OR s.min_value IS DISTINCT FROM raw.mn
     OR s.max_value IS DISTINCT FROM raw.mx
$func$;

REVOKE ALL ON FUNCTION public.health4ai_recompute_mismatches(uuid, text, date, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.health4ai_recompute_mismatches(uuid, text, date, text) TO service_role;
