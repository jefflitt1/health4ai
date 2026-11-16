-- Optional workout_details_v1. Not in the default installer. See deployment packet.
BEGIN;
CREATE TABLE public.healthkit_workout_exports (
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  workout_uuid uuid NOT NULL,
  export_uuid uuid NOT NULL,
  revision bigint GENERATED ALWAYS AS IDENTITY,
  query_types text[] NOT NULL,
  observed_count integer CHECK (observed_count BETWEEN 0 AND 100000),
  completed_at timestamptz,
  is_current boolean NOT NULL DEFAULT false,
  PRIMARY KEY (user_id, workout_uuid, export_uuid),
  CHECK (NOT is_current OR completed_at IS NOT NULL)
);
CREATE UNIQUE INDEX healthkit_workout_one_current
  ON public.healthkit_workout_exports(user_id, workout_uuid) WHERE is_current;
CREATE TABLE public.healthkit_workout_samples (
  user_id uuid NOT NULL,
  workout_uuid uuid NOT NULL,
  export_uuid uuid NOT NULL,
  sample_uuid uuid NOT NULL,
  metric_type text NOT NULL,
  value double precision NOT NULL CHECK (value NOT IN ('NaN'::float8, 'Infinity'::float8, '-Infinity'::float8)),
  unit text NOT NULL CHECK (length(unit) BETWEEN 1 AND 64),
  source_device text NOT NULL CHECK (length(source_device) BETWEEN 1 AND 256),
  started_at timestamptz NOT NULL CHECK (isfinite(started_at)),
  ended_at timestamptz NOT NULL CHECK (isfinite(ended_at) AND ended_at >= started_at),
  PRIMARY KEY (user_id, workout_uuid, export_uuid, sample_uuid),
  FOREIGN KEY (user_id, workout_uuid, export_uuid)
    REFERENCES public.healthkit_workout_exports ON DELETE CASCADE
);
ALTER TABLE public.healthkit_workout_exports ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.healthkit_workout_samples ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.healthkit_workout_exports, public.healthkit_workout_samples FROM PUBLIC, anon, authenticated, service_role;
-- Reads for the trusted MCP/ingest service; all writes go through the serialized RPC.
GRANT SELECT ON public.healthkit_workout_exports, public.healthkit_workout_samples TO service_role;

CREATE FUNCTION public.health4ai_workout_details_v1(
  p_user_id uuid, p_operation text, p_workout_uuid uuid,
  p_export_uuid uuid, p_payload jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE
  e public.healthkit_workout_exports%ROWTYPE;
  allowed text[] := ARRAY['HKQuantityTypeIdentifierHeartRate','HKQuantityTypeIdentifierRunningSpeed',
    'HKQuantityTypeIdentifierRunningPower','HKQuantityTypeIdentifierRunningStrideLength',
    'HKQuantityTypeIdentifierRunningVerticalOscillation','HKQuantityTypeIdentifierRunningGroundContactTime',
    'HKQuantityTypeIdentifierStepCount'];
  types text[];
  n integer;
  actual integer;
  item jsonb;
  existing public.healthkit_workout_samples%ROWTYPE;
BEGIN
  IF p_user_id IS NULL OR jsonb_typeof(p_payload) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'invalid_request' USING ERRCODE = '22023';
  END IF;
  IF p_operation = 'capabilities' THEN
    RETURN '{"capabilities":["workout_details_v1"]}'::jsonb;
  END IF;
  -- Tenant lock also serializes erase-all with every in-flight write.
  PERFORM pg_advisory_xact_lock(hashtextextended(p_user_id::text, 0));
  IF p_operation = 'delete_all' THEN
    DELETE FROM public.healthkit_workout_exports WHERE user_id=p_user_id;
    GET DIAGNOSTICS n = ROW_COUNT;
    RETURN jsonb_build_object('deleted_exports', n);
  END IF;
  IF p_workout_uuid IS NULL THEN RAISE EXCEPTION 'invalid_workout' USING ERRCODE='22023'; END IF;
  IF p_operation = 'delete' THEN
    DELETE FROM public.healthkit_workout_exports WHERE user_id=p_user_id AND workout_uuid=p_workout_uuid;
    GET DIAGNOSTICS n = ROW_COUNT;
    RETURN jsonb_build_object('deleted_exports', n);
  END IF;
  IF p_export_uuid IS NULL THEN RAISE EXCEPTION 'invalid_export' USING ERRCODE='22023'; END IF;
  SELECT * INTO e FROM public.healthkit_workout_exports
    WHERE user_id=p_user_id AND workout_uuid=p_workout_uuid AND export_uuid=p_export_uuid;
  IF p_operation = 'begin' THEN
    IF jsonb_typeof(p_payload->'query_types') IS DISTINCT FROM 'array' THEN
      RAISE EXCEPTION 'invalid_types' USING ERRCODE='22023';
    END IF;
    SELECT array_agg(t ORDER BY t) INTO types FROM jsonb_array_elements_text(p_payload->'query_types') t;
    IF types IS NULL OR cardinality(types)>7 OR NOT types <@ allowed
      OR cardinality(types) <> (SELECT count(DISTINCT x) FROM unnest(types) x) THEN
      RAISE EXCEPTION 'invalid_types' USING ERRCODE='22023';
    END IF;
    IF e.export_uuid IS NOT NULL THEN
      IF e.query_types <> types THEN RAISE EXCEPTION 'revision_conflict' USING ERRCODE='22023'; END IF;
      RETURN jsonb_build_object('export_uuid',e.export_uuid,'complete',e.completed_at IS NOT NULL);
    END IF;
    IF (SELECT count(*) FROM public.healthkit_workout_exports WHERE user_id=p_user_id AND workout_uuid=p_workout_uuid)>=16 THEN
      RAISE EXCEPTION 'revision_limit' USING ERRCODE='22023';
    END IF;
    INSERT INTO public.healthkit_workout_exports(user_id,workout_uuid,export_uuid,query_types)
      VALUES(p_user_id,p_workout_uuid,p_export_uuid,types);
    RETURN jsonb_build_object('export_uuid',p_export_uuid,'complete',false);
  END IF;
  IF e.export_uuid IS NULL THEN RAISE EXCEPTION 'export_not_found' USING ERRCODE='22023'; END IF;
  IF p_operation = 'page' THEN
    IF e.completed_at IS NOT NULL THEN RAISE EXCEPTION 'immutable_export' USING ERRCODE='22023'; END IF;
    IF jsonb_typeof(p_payload->'samples') IS DISTINCT FROM 'array' THEN
      RAISE EXCEPTION 'invalid_page' USING ERRCODE='22023';
    END IF;
    n := jsonb_array_length(p_payload->'samples');
    -- HTTP enforces 256 KiB actual bytes; JSONB adds formatting whitespace.
    IF n NOT BETWEEN 1 AND 500 OR octet_length(p_payload::text)>524288 THEN
      RAISE EXCEPTION 'invalid_page' USING ERRCODE='22023';
    END IF;
    FOR item IN SELECT * FROM jsonb_array_elements(p_payload->'samples') LOOP
      IF NOT (item->>'metric_type' = ANY(e.query_types)) THEN
        RAISE EXCEPTION 'unqueried_type' USING ERRCODE='22023';
      END IF;
      SELECT * INTO existing FROM public.healthkit_workout_samples WHERE user_id=p_user_id
        AND workout_uuid=p_workout_uuid AND export_uuid=p_export_uuid AND sample_uuid=(item->>'sample_uuid')::uuid;
      IF existing.sample_uuid IS NOT NULL THEN
        IF ROW(existing.metric_type,existing.value,existing.unit,existing.source_device,existing.started_at,existing.ended_at)
          IS DISTINCT FROM ROW(item->>'metric_type',(item->>'value')::float8,item->>'unit',item->>'source_device',
                              (item->>'started_at')::timestamptz,(item->>'ended_at')::timestamptz) THEN
          RAISE EXCEPTION 'sample_conflict' USING ERRCODE='22023';
        END IF;
      ELSE
        INSERT INTO public.healthkit_workout_samples VALUES(p_user_id,p_workout_uuid,p_export_uuid,
          (item->>'sample_uuid')::uuid,item->>'metric_type',(item->>'value')::float8,item->>'unit',
          item->>'source_device',(item->>'started_at')::timestamptz,(item->>'ended_at')::timestamptz);
      END IF;
    END LOOP;
    SELECT count(*) INTO actual FROM public.healthkit_workout_samples
      WHERE user_id=p_user_id AND workout_uuid=p_workout_uuid AND export_uuid=p_export_uuid;
    IF actual>100000 THEN RAISE EXCEPTION 'sample_limit' USING ERRCODE='22023'; END IF;
    RETURN jsonb_build_object('observed_count',actual);
  ELSIF p_operation = 'finalize' THEN
    n := (p_payload->>'observed_count')::integer;
    IF n IS NULL OR n NOT BETWEEN 0 AND 100000 THEN RAISE EXCEPTION 'invalid_count' USING ERRCODE='22023'; END IF;
    SELECT count(*) INTO actual FROM public.healthkit_workout_samples
      WHERE user_id=p_user_id AND workout_uuid=p_workout_uuid AND export_uuid=p_export_uuid;
    IF actual<>n THEN RAISE EXCEPTION 'count_mismatch' USING ERRCODE='22023'; END IF;
    IF EXISTS(SELECT 1 FROM public.healthkit_workout_exports WHERE user_id=p_user_id
      AND workout_uuid=p_workout_uuid AND is_current AND revision>e.revision) THEN
      RAISE EXCEPTION 'stale_revision' USING ERRCODE='22023';
    END IF;
    UPDATE public.healthkit_workout_exports SET is_current=false
      WHERE user_id=p_user_id AND workout_uuid=p_workout_uuid AND is_current AND export_uuid<>p_export_uuid;
    UPDATE public.healthkit_workout_exports SET is_current=true,observed_count=n,completed_at=COALESCE(completed_at,now())
      WHERE user_id=p_user_id AND workout_uuid=p_workout_uuid AND export_uuid=p_export_uuid;
    RETURN jsonb_build_object('export_uuid',p_export_uuid,'observed_count',n,'complete',true,'coverage','observed_only');
  END IF;
  RAISE EXCEPTION 'invalid_operation' USING ERRCODE='22023';
END $$;
REVOKE ALL ON FUNCTION public.health4ai_workout_details_v1(uuid,text,uuid,uuid,jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.health4ai_workout_details_v1(uuid,text,uuid,uuid,jsonb) TO service_role;
COMMIT;
