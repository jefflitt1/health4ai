-- Drop the never-populated wide table (was planned for a webhook pipeline that was
-- superseded by the iOS direct-sync app). Cascades to v_jeff_biometrics_combined.
DROP TABLE IF EXISTS public.jeff_apple_health_daily CASCADE;

-- Helper view: unified quantity metrics across the rolling 60-day boundary.
-- Summarized days (older than 60d) live in healthkit_daily_summaries;
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

-- Combined Oura + Apple Watch biometrics view (rolling 90 days).
-- Apple Health side pivots from v_healthkit_daily_quantity.
-- Sleep columns intentionally omitted: Apple Watch vs Oura sleep requires
-- source-device filtering on raw category data (separate feature).
-- SpO2 stored as fraction (0-1) in healthkit_metrics/summaries, multiplied by 100 here.
-- AppleStandTime stored in minutes, divided by 60 for stand_hours.
CREATE OR REPLACE VIEW public.v_jeff_biometrics_combined AS
WITH apple AS (
    SELECT
        day,
        MAX(CASE WHEN metric_type = 'HKQuantityTypeIdentifierHeartRateVariabilitySDNN' THEN avg_value END)        AS hrv_sdnn,
        MAX(CASE WHEN metric_type = 'HKQuantityTypeIdentifierRestingHeartRate'          THEN avg_value END)        AS resting_heart_rate,
        MAX(CASE WHEN metric_type = 'HKQuantityTypeIdentifierOxygenSaturation'          THEN avg_value * 100 END)  AS spo2_avg,
        MAX(CASE WHEN metric_type = 'HKQuantityTypeIdentifierOxygenSaturation'          THEN min_value * 100 END)  AS spo2_min,
        MAX(CASE WHEN metric_type = 'HKQuantityTypeIdentifierStepCount'                 THEN sum_value END)        AS steps,
        MAX(CASE WHEN metric_type = 'HKQuantityTypeIdentifierActiveEnergyBurned'        THEN sum_value END)        AS active_energy,
        MAX(CASE WHEN metric_type = 'HKQuantityTypeIdentifierAppleExerciseTime'         THEN sum_value END)        AS exercise_minutes,
        ROUND((MAX(CASE WHEN metric_type = 'HKQuantityTypeIdentifierAppleStandTime' THEN sum_value END) / 60.0)::numeric, 1) AS stand_hours
    FROM public.v_healthkit_daily_quantity
    WHERE day >= CURRENT_DATE - INTERVAL '90 days'
    GROUP BY day
)
SELECT
    COALESCE(o.day, a.day)                                 AS day,
    o.readiness_score,
    o.average_hrv                                          AS oura_hrv_rmssd,
    a.hrv_sdnn                                             AS apple_hrv_sdnn,
    o.resting_heart_rate                                   AS oura_rhr,
    a.resting_heart_rate                                   AS apple_rhr,
    o.temperature_deviation,
    o.spo2_average                                         AS oura_spo2,
    a.spo2_avg                                             AS apple_spo2,
    a.spo2_min                                             AS apple_spo2_min,
    o.sleep_score,
    ROUND(o.total_sleep_duration::numeric / 3600.0, 1)    AS oura_sleep_hours,
    o.sleep_efficiency,
    o.activity_score,
    o.steps                                                AS oura_steps,
    a.steps                                                AS apple_steps,
    o.active_calories                                      AS oura_active_cal,
    a.active_energy                                        AS apple_active_cal,
    a.exercise_minutes,
    a.stand_hours
FROM public.jeff_oura_daily o
FULL JOIN apple a ON o.day = a.day
WHERE COALESCE(o.day, a.day) >= CURRENT_DATE - INTERVAL '90 days'
ORDER BY COALESCE(o.day, a.day) DESC;
