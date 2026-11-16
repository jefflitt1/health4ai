-- Merged hourly totals replace per-device rows. Body copied verbatim from
-- supabase/bootstrap/002_health4ai_prod_rls.sql section 5; only the Supabase role grants after it
-- are dropped, since those roles do not exist here and only the ingest function calls this.
--
-- ---------------------------------------------------------------------------
-- For activity types that several devices record at the same moment (steps, distance,
-- energy, flights, exercise/move/stand time) the app sends HealthKit's merged total per UTC
-- hour, labelled source_device 'HealthKit (all sources)'. Rows already stored per device for
-- that hour would be summed on top of it: an iPhone and a Watch counting the same steps is
-- how 2021 came to read 67% high. So the hour's per-device rows are deleted and the merged
-- row written in ONE transaction; done as two requests, a failure between them left the hour
-- either double-counted or empty. A per-device row belongs to the hour its started_at falls
-- in, so a sample crossing a boundary is replaced when the hour it started in arrives.
-- Register D361.
-- One DELETE per hour with constant bounds: a single DELETE .. USING jsonb_to_recordset
-- cannot push the hour range into an index (bounds come from the recordset), planned as a
-- full-table scan and hit PostgREST's 8 s statement timeout on any project with real
-- history (measured 2026-09-13, 15 s for a two-hour payload). Still one transaction.
CREATE OR REPLACE FUNCTION public.health4ai_replace_merged_hours(
  p_user_id uuid,
  p_rows    jsonb
)
RETURNS TABLE(deleted_count bigint, written_count bigint)
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = pg_catalog, public
AS $func$
DECLARE
  v_deleted bigint := 0;
  v_written bigint;
  v_n       bigint;
  r         record;
BEGIN
  IF p_user_id IS NULL THEN
    RAISE EXCEPTION 'p_user_id is required';
  END IF;
  IF p_rows IS NULL OR jsonb_typeof(p_rows) <> 'array' THEN
    RAISE EXCEPTION 'p_rows must be a JSON array';
  END IF;

  FOR r IN
    SELECT DISTINCT x.metric_type, x.started_at
    FROM jsonb_to_recordset(p_rows) AS x(metric_type text, started_at timestamptz)
  LOOP
    DELETE FROM public.healthkit_metrics m
    WHERE m.user_id = p_user_id
      AND m.metric_type = r.metric_type
      AND m.started_at >= r.started_at
      AND m.started_at <  r.started_at + interval '1 hour'
      AND m.source_device <> 'HealthKit (all sources)';
    GET DIAGNOSTICS v_n = ROW_COUNT;
    v_deleted := v_deleted + v_n;
  END LOOP;

  INSERT INTO public.healthkit_metrics
    (user_id, metric_type, value, unit, source_device, started_at, ended_at, metadata)
  SELECT p_user_id, x.metric_type, x.value, x.unit, 'HealthKit (all sources)',
         x.started_at, x.ended_at, x.metadata
  FROM jsonb_to_recordset(p_rows) AS x(metric_type text, value double precision, unit text,
                                       started_at timestamptz, ended_at timestamptz, metadata jsonb)
  ON CONFLICT (user_id, metric_type, source_device, started_at) DO UPDATE SET
    value = EXCLUDED.value, unit = EXCLUDED.unit,
    ended_at = EXCLUDED.ended_at, metadata = EXCLUDED.metadata;
  GET DIAGNOSTICS v_written = ROW_COUNT;

  RETURN QUERY SELECT v_deleted, v_written;
END;
$func$;
