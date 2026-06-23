-- Nightly sleep summary view (Core + Deep + REM only, value IN (3,4,5), Oura source only).
-- Oura Ring syncs its sleep stages to Apple Health; Apple Watch also writes stages.
-- Filtering to source_device ILIKE '%Oura%' prevents double-counting (both devices write
-- the same night with slightly different started_at timestamps, bypassing the unique key).
-- Night boundary: any segment starting before 06:00 local time counts as the prior night.
-- Example: GET /rest/v1/v_healthkit_sleep_nightly?user_id=eq.{uid}&night_date=eq.{yesterday}

CREATE OR REPLACE VIEW public.v_healthkit_sleep_nightly AS
SELECT
    user_id,
    (date_trunc('day', (started_at AT TIME ZONE 'America/New_York') - interval '6 hours'))::date
        AS night_date,
    round(
        sum(extract(epoch from (ended_at - started_at)) / 3600.0)::numeric,
        2
    ) AS sleep_hours,
    round(
        sum(CASE WHEN value = 4.0
            THEN extract(epoch from (ended_at - started_at)) / 60.0 ELSE 0 END)::numeric,
        1
    ) AS deep_minutes,
    round(
        sum(CASE WHEN value = 5.0
            THEN extract(epoch from (ended_at - started_at)) / 60.0 ELSE 0 END)::numeric,
        1
    ) AS rem_minutes,
    count(*) AS segment_count
FROM public.healthkit_metrics
WHERE metric_type = 'HKCategoryTypeIdentifierSleepAnalysis'
  AND value IN (3.0, 4.0, 5.0)
  AND ended_at IS NOT NULL
  AND source_device ILIKE '%Oura%'
GROUP BY user_id, night_date;
