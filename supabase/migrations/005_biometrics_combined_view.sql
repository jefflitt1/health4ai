-- Helper view: unified quantity metrics across the rolling retention boundary.
-- Summarized days (older than RAW_CUTOFF_DAYS) live in healthkit_daily_summaries;
-- recent days (within the raw window) are aggregated live from healthkit_metrics.
CREATE OR REPLACE VIEW public.v_healthkit_daily_quantity AS
SELECT user_id, date AS day, metric_type, avg_value, min_value, max_value, sum_value, sample_count
FROM public.healthkit_daily_summaries
UNION ALL
SELECT
    user_id,
    (started_at AT TIME ZONE 'America/New_York')::date AS day,
    metric_type,
    AVG(value)::double precision   AS avg_value,
    MIN(value)::double precision   AS min_value,
    MAX(value)::double precision   AS max_value,
    SUM(value)::double precision   AS sum_value,
    COUNT(*)::integer              AS sample_count
FROM public.healthkit_metrics
WHERE metric_type NOT LIKE 'HKCategoryTypeIdentifier%'
  AND metric_type NOT LIKE 'HKWorkoutTypeIdentifier%'
GROUP BY user_id, (started_at AT TIME ZONE 'America/New_York')::date, metric_type;
