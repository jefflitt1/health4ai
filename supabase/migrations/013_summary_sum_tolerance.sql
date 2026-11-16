-- Float aggregation order can change SUM by one ULP without changing any sample.
-- Keep the established absolute 1e-6 sum tolerance; counts/min/max remain exact.
-- Explicit NULL/nonfinite checks preserve detection of missing/corrupt aggregates.
-- Preserve ownership; explicitly restrict execution to the service role below.
-- No data is changed by applying these definitions.
BEGIN;
CREATE OR REPLACE FUNCTION public.health4ai_compact_metric_v2(p_user_id uuid, p_metric_type text, p_cutoff date, p_quiet interval DEFAULT '24:00:00'::interval, p_tz text DEFAULT 'America/New_York'::text)
 RETURNS TABLE(mode text, raw_rows bigint, summary_rows bigint, skipped_days bigint)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
DECLARE
  v_cutoff_ts timestamptz := (p_cutoff::timestamp AT TIME ZONE p_tz);
  v_raw       bigint := 0;
  v_sum       bigint := 0;
  v_skipped   bigint := 0;
  c_merged    constant text := 'HealthKit (all sources)';
  c_merged_types constant text[] := ARRAY[
    'HKQuantityTypeIdentifierStepCount','HKQuantityTypeIdentifierDistanceWalkingRunning',
    'HKQuantityTypeIdentifierDistanceCycling','HKQuantityTypeIdentifierDistanceSwimming',
    'HKQuantityTypeIdentifierDistanceWheelchair','HKQuantityTypeIdentifierDistanceDownhillSnowSports',
    'HKQuantityTypeIdentifierPushCount','HKQuantityTypeIdentifierSwimmingStrokeCount',
    'HKQuantityTypeIdentifierFlightsClimbed','HKQuantityTypeIdentifierActiveEnergyBurned',
    'HKQuantityTypeIdentifierBasalEnergyBurned','HKQuantityTypeIdentifierAppleExerciseTime',
    'HKQuantityTypeIdentifierAppleMoveTime','HKQuantityTypeIdentifierAppleStandTime'];
BEGIN
  IF p_metric_type LIKE 'HKCategoryTypeIdentifier%' OR p_metric_type = 'HKWorkoutTypeIdentifier' THEN
    RAISE EXCEPTION 'health4ai_compact_metric_v2: % is never compacted (categorical or workout payload)', p_metric_type;
  END IF;
  IF p_metric_type = ANY (c_merged_types) THEN
    SELECT count(*) INTO v_skipped FROM (
      SELECT 1 FROM public.healthkit_metrics
      WHERE user_id = p_user_id AND metric_type = p_metric_type AND started_at < v_cutoff_ts
      GROUP BY (started_at AT TIME ZONE p_tz)::date
      HAVING bool_or(source_device <> c_merged)) s;

    INSERT INTO public.healthkit_daily_summaries
      (user_id, metric_type, date, avg_value, min_value, max_value, sum_value, sample_count, unit)
    SELECT user_id, metric_type, (started_at AT TIME ZONE p_tz)::date,
           avg(value), min(value), max(value), sum(value), count(*), coalesce(unit, '')
    FROM public.healthkit_metrics
    WHERE user_id = p_user_id AND metric_type = p_metric_type AND started_at < v_cutoff_ts
    GROUP BY user_id, metric_type, (started_at AT TIME ZONE p_tz)::date, coalesce(unit, '')
    HAVING bool_and(source_device = c_merged)
    ON CONFLICT (user_id, metric_type, date, unit) DO UPDATE SET
      avg_value = EXCLUDED.avg_value, min_value = EXCLUDED.min_value, max_value = EXCLUDED.max_value,
      sum_value = EXCLUDED.sum_value, sample_count = EXCLUDED.sample_count, summarized_at = now()
    WHERE (healthkit_daily_summaries.sum_value IS DISTINCT FROM EXCLUDED.sum_value AND (
          (healthkit_daily_summaries.sum_value IS NULL) <> (EXCLUDED.sum_value IS NULL)
       OR abs(healthkit_daily_summaries.sum_value - EXCLUDED.sum_value) > 1e-6
       OR healthkit_daily_summaries.sum_value IN ('NaN'::float8, 'Infinity'::float8, '-Infinity'::float8)
       OR EXCLUDED.sum_value IN ('NaN'::float8, 'Infinity'::float8, '-Infinity'::float8)))
       OR healthkit_daily_summaries.sample_count IS DISTINCT FROM EXCLUDED.sample_count
       OR healthkit_daily_summaries.min_value    IS DISTINCT FROM EXCLUDED.min_value
       OR healthkit_daily_summaries.max_value    IS DISTINCT FROM EXCLUDED.max_value;
    GET DIAGNOSTICS v_sum = ROW_COUNT;
    RETURN QUERY SELECT 'recompute'::text, 0::bigint, v_sum, v_skipped;
    RETURN;
  END IF;

  WITH del AS (
    DELETE FROM public.healthkit_metrics m
    WHERE m.user_id = p_user_id AND m.metric_type = p_metric_type
      AND m.started_at < v_cutoff_ts
      AND m.synced_at < now() - p_quiet
    RETURNING m.user_id, m.metric_type, m.value, m.unit, m.started_at
  ), agg AS (
    SELECT user_id, metric_type, (started_at AT TIME ZONE p_tz)::date AS d, coalesce(unit, '') AS unit,
           sum(value) AS s, min(value) AS mn, max(value) AS mx, count(*) AS c
    FROM del GROUP BY 1, 2, 3, 4
  ), ins AS (
    INSERT INTO public.healthkit_daily_summaries
      (user_id, metric_type, date, avg_value, min_value, max_value, sum_value, sample_count, unit)
    SELECT user_id, metric_type, d, s / nullif(c, 0), mn, mx, s, c, unit FROM agg
    ON CONFLICT (user_id, metric_type, date, unit) DO UPDATE SET
      sum_value    = coalesce(healthkit_daily_summaries.sum_value, 0) + coalesce(EXCLUDED.sum_value, 0),
      sample_count = healthkit_daily_summaries.sample_count + EXCLUDED.sample_count,
      min_value    = least(healthkit_daily_summaries.min_value, EXCLUDED.min_value),
      max_value    = greatest(healthkit_daily_summaries.max_value, EXCLUDED.max_value),
      avg_value    = (coalesce(healthkit_daily_summaries.sum_value, 0) + coalesce(EXCLUDED.sum_value, 0))
                     / nullif(healthkit_daily_summaries.sample_count + EXCLUDED.sample_count, 0),
      summarized_at = now()
    RETURNING 1
  )
  SELECT (SELECT count(*) FROM del), (SELECT count(*) FROM ins) INTO v_raw, v_sum;
  RETURN QUERY SELECT 'compact'::text, v_raw, v_sum, 0::bigint;
END;
$function$;
CREATE OR REPLACE FUNCTION public.health4ai_recompute_mismatches(p_user_id uuid, p_metric_type text, p_cutoff date, p_tz text DEFAULT 'America/New_York'::text)
 RETURNS TABLE(day date, unit text, raw_sum double precision, summary_sum double precision, raw_rows bigint, summary_samples integer)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
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
     OR (s.sum_value IS DISTINCT FROM raw.s AND (
        (s.sum_value IS NULL) <> (raw.s IS NULL)
     OR abs(s.sum_value - raw.s) > 1e-6
     OR s.sum_value IN ('NaN'::float8, 'Infinity'::float8, '-Infinity'::float8)
     OR raw.s IN ('NaN'::float8, 'Infinity'::float8, '-Infinity'::float8)))
     OR s.sample_count IS DISTINCT FROM raw.c
     OR s.min_value IS DISTINCT FROM raw.mn
     OR s.max_value IS DISTINCT FROM raw.mx
$function$;
REVOKE ALL ON FUNCTION public.health4ai_compact_metric_v2(uuid, text, date, interval, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.health4ai_recompute_mismatches(uuid, text, date, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.health4ai_compact_metric_v2(uuid, text, date, interval, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.health4ai_recompute_mismatches(uuid, text, date, text) TO service_role;
COMMIT;
