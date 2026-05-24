-- Transactional, volume-safe summarization function.
-- Aggregates raw rows older than p_cutoff into daily summaries, then deletes
-- the raws — all in one transaction. No row-count cap, no partial-delete risk.
-- Only call for high-volume QUANTITY types; never for category/workout types
-- (their value is categorical and the metadata payload would be lost).

CREATE OR REPLACE FUNCTION public.summarize_healthkit_metric(
    p_user_id uuid,
    p_metric_type text,
    p_cutoff date
)
RETURNS TABLE(raw_count bigint, summary_days bigint) AS $func$
DECLARE
    v_raw_count bigint;
    v_summary_days bigint;
BEGIN
    SELECT COUNT(*) INTO v_raw_count
    FROM public.healthkit_metrics
    WHERE user_id = p_user_id AND metric_type = p_metric_type
      AND started_at < p_cutoff::timestamptz;

    IF v_raw_count = 0 THEN
        RETURN QUERY SELECT 0::bigint, 0::bigint;
        RETURN;
    END IF;

    INSERT INTO public.healthkit_daily_summaries
        (user_id, metric_type, date, avg_value, min_value, max_value, sum_value, sample_count, unit)
    SELECT user_id, metric_type, (started_at AT TIME ZONE 'America/New_York')::date,
        AVG(value), MIN(value), MAX(value), SUM(value), COUNT(*), MAX(unit)
    FROM public.healthkit_metrics
    WHERE user_id = p_user_id AND metric_type = p_metric_type
      AND started_at < p_cutoff::timestamptz
    GROUP BY user_id, metric_type, (started_at AT TIME ZONE 'America/New_York')::date
    ON CONFLICT (user_id, metric_type, date) DO UPDATE SET
        avg_value = EXCLUDED.avg_value, min_value = EXCLUDED.min_value,
        max_value = EXCLUDED.max_value, sum_value = EXCLUDED.sum_value,
        sample_count = EXCLUDED.sample_count, unit = EXCLUDED.unit, summarized_at = now();

    GET DIAGNOSTICS v_summary_days = ROW_COUNT;

    DELETE FROM public.healthkit_metrics
    WHERE user_id = p_user_id AND metric_type = p_metric_type
      AND started_at < p_cutoff::timestamptz;

    RETURN QUERY SELECT v_raw_count, v_summary_days;
END;
$func$ LANGUAGE plpgsql SECURITY DEFINER;
