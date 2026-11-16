-- Both paths lock each person until transaction end before changing metric rows.
CREATE OR REPLACE FUNCTION public.health4ai_upsert_device_rows(p_rows jsonb)
RETURNS bigint LANGUAGE plpgsql SECURITY INVOKER SET search_path = pg_catalog, public
AS $func$
DECLARE v_written bigint; v_user uuid;
BEGIN
  -- Deterministic order for batches; the endpoint normally supplies one person.
  FOR v_user IN SELECT DISTINCT x.user_id FROM jsonb_to_recordset(p_rows) AS x(user_id uuid)
               ORDER BY x.user_id
  LOOP
    PERFORM 1 FROM public.people WHERE id = v_user FOR UPDATE;
  END LOOP;
  INSERT INTO public.healthkit_metrics
    (user_id, metric_type, value, unit, source_device, started_at, ended_at, metadata)
  SELECT r.user_id, r.metric_type, r.value, r.unit, r.source_device, r.started_at, r.ended_at, r.metadata
    FROM jsonb_to_recordset(p_rows) AS r(user_id uuid, metric_type text, value float8,
      unit text, source_device text, started_at timestamptz, ended_at timestamptz, metadata jsonb)
   WHERE NOT EXISTS (
     SELECT 1 FROM public.healthkit_metrics m
      WHERE m.user_id = r.user_id AND m.metric_type = r.metric_type
        AND m.source_device = 'HealthKit (all sources)'
        AND m.started_at <= r.started_at AND m.started_at > r.started_at - interval '1 hour'
   )
  ON CONFLICT (user_id, metric_type, source_device, started_at) DO UPDATE SET
    value = EXCLUDED.value, unit = EXCLUDED.unit, ended_at = EXCLUDED.ended_at,
    metadata = EXCLUDED.metadata, synced_at = now();
  GET DIAGNOSTICS v_written = ROW_COUNT;
  RETURN v_written;
END;
$func$;

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

  -- Both writers lock the same person before a fresh read of the metric rows.
  PERFORM 1 FROM public.people WHERE id = p_user_id FOR UPDATE;

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
