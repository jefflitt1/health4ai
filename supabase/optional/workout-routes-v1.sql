-- Optional location storage. Separate opt-in/capability; never in default bootstrap.
BEGIN;
CREATE TABLE public.healthkit_workout_route_exports (
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  workout_uuid uuid NOT NULL, export_uuid uuid NOT NULL,
  revision bigint GENERATED ALWAYS AS IDENTITY,
  routes jsonb NOT NULL,
  invalid_counts jsonb,
  completed_at timestamptz,
  is_current boolean NOT NULL DEFAULT false,
  PRIMARY KEY(user_id,workout_uuid,export_uuid),
  CHECK(NOT is_current OR completed_at IS NOT NULL)
);
CREATE UNIQUE INDEX healthkit_workout_route_one_current
  ON public.healthkit_workout_route_exports(user_id,workout_uuid) WHERE is_current;
CREATE TABLE public.healthkit_workout_route_points (
  user_id uuid NOT NULL, workout_uuid uuid NOT NULL, export_uuid uuid NOT NULL,
  route_uuid uuid NOT NULL, point_index integer NOT NULL CHECK(point_index>=0),
  timestamp timestamptz NOT NULL CHECK(isfinite(timestamp)),
  latitude double precision NOT NULL CHECK(latitude BETWEEN -90 AND 90),
  longitude double precision NOT NULL CHECK(longitude BETWEEN -180 AND 180),
  altitude double precision CHECK(altitude NOT IN ('NaN'::float8,'Infinity'::float8,'-Infinity'::float8)),
  horizontal_accuracy double precision NOT NULL CHECK(horizontal_accuracy>=0 AND horizontal_accuracy<'Infinity'::float8),
  vertical_accuracy double precision NOT NULL CHECK(vertical_accuracy NOT IN ('NaN'::float8,'Infinity'::float8,'-Infinity'::float8)),
  CHECK(vertical_accuracy>=0 OR altitude IS NULL),
  PRIMARY KEY(user_id,workout_uuid,export_uuid,route_uuid,point_index),
  FOREIGN KEY(user_id,workout_uuid,export_uuid) REFERENCES public.healthkit_workout_route_exports ON DELETE CASCADE
);
ALTER TABLE public.healthkit_workout_route_exports ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.healthkit_workout_route_points ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.healthkit_workout_route_exports,public.healthkit_workout_route_points FROM PUBLIC,anon,authenticated,service_role;
GRANT SELECT ON public.healthkit_workout_route_exports,public.healthkit_workout_route_points TO service_role;
CREATE FUNCTION public.health4ai_workout_routes_v1(
  p_user_id uuid,p_operation text,p_workout_uuid uuid,p_export_uuid uuid,p_payload jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE
  e public.healthkit_workout_route_exports%ROWTYPE;
  prior public.healthkit_workout_route_points%ROWTYPE;
  spec jsonb; item jsonb; ordered jsonb; counts jsonb;
  source_count integer; invalid_count integer; actual integer; n integer;
BEGIN
  IF p_user_id IS NULL OR jsonb_typeof(p_payload) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'invalid_request' USING ERRCODE='22023';
  END IF;
  IF p_operation='capabilities' THEN RETURN '{"capabilities":["workout_routes_v1"]}'::jsonb; END IF;
  -- Same tenant lock as quantity-detail erase/write operations.
  PERFORM pg_advisory_xact_lock(hashtextextended(p_user_id::text,0));
  IF p_operation='delete_all' THEN
    DELETE FROM public.healthkit_workout_route_exports WHERE user_id=p_user_id;
    GET DIAGNOSTICS n=ROW_COUNT;
    RETURN jsonb_build_object('deleted_exports',n);
  END IF;
  IF p_workout_uuid IS NULL THEN RAISE EXCEPTION 'invalid_workout' USING ERRCODE='22023'; END IF;
  IF p_operation='delete' THEN
    DELETE FROM public.healthkit_workout_route_exports WHERE user_id=p_user_id AND workout_uuid=p_workout_uuid;
    GET DIAGNOSTICS n=ROW_COUNT;
    RETURN jsonb_build_object('deleted_exports',n);
  END IF;
  IF p_export_uuid IS NULL THEN RAISE EXCEPTION 'invalid_export' USING ERRCODE='22023'; END IF;
  SELECT * INTO e FROM public.healthkit_workout_route_exports
    WHERE user_id=p_user_id AND workout_uuid=p_workout_uuid AND export_uuid=p_export_uuid;
  IF p_operation='begin' THEN
    IF jsonb_typeof(p_payload->'routes') IS DISTINCT FROM 'array' OR jsonb_array_length(p_payload->'routes')>32 THEN
      RAISE EXCEPTION 'invalid_routes' USING ERRCODE='22023';
    END IF;
    n:=0;
    FOR spec IN SELECT * FROM jsonb_array_elements(p_payload->'routes') LOOP
      PERFORM (spec->>'route_uuid')::uuid;
      source_count:=(spec->>'source_count')::integer;
      IF spec->>'route_uuid' IS NULL OR source_count IS NULL OR source_count NOT BETWEEN 0 AND 100000 THEN
        RAISE EXCEPTION 'invalid_routes' USING ERRCODE='22023';
      END IF;
      n:=n+source_count;
    END LOOP;
    IF n>100000 OR jsonb_array_length(p_payload->'routes')<>(SELECT count(DISTINCT (x->>'route_uuid')::uuid)
       FROM jsonb_array_elements(p_payload->'routes') x) THEN
      RAISE EXCEPTION 'invalid_routes' USING ERRCODE='22023';
    END IF;
    SELECT COALESCE(jsonb_agg(jsonb_build_object('route_uuid',(x->>'route_uuid')::uuid,'source_count',(x->>'source_count')::integer)
      ORDER BY (x->>'route_uuid')::uuid),'[]'::jsonb) INTO ordered FROM jsonb_array_elements(p_payload->'routes') x;
    IF e.export_uuid IS NOT NULL THEN
      IF e.routes<>ordered THEN RAISE EXCEPTION 'revision_conflict' USING ERRCODE='22023'; END IF;
      RETURN jsonb_build_object('export_uuid',p_export_uuid,'complete',e.completed_at IS NOT NULL);
    END IF;
    IF (SELECT count(*) FROM public.healthkit_workout_route_exports WHERE user_id=p_user_id AND workout_uuid=p_workout_uuid)>=16 THEN
      RAISE EXCEPTION 'revision_limit' USING ERRCODE='22023';
    END IF;
    INSERT INTO public.healthkit_workout_route_exports(user_id,workout_uuid,export_uuid,routes)
      VALUES(p_user_id,p_workout_uuid,p_export_uuid,ordered);
    RETURN jsonb_build_object('export_uuid',p_export_uuid,'complete',false);
  END IF;
  IF e.export_uuid IS NULL THEN RAISE EXCEPTION 'export_not_found' USING ERRCODE='22023'; END IF;
  IF p_operation='page' THEN
    IF e.completed_at IS NOT NULL THEN RAISE EXCEPTION 'immutable_export' USING ERRCODE='22023'; END IF;
    IF jsonb_typeof(p_payload->'points') IS DISTINCT FROM 'array' THEN RAISE EXCEPTION 'invalid_page' USING ERRCODE='22023'; END IF;
    n:=jsonb_array_length(p_payload->'points');
    -- HTTP enforces 256 KiB actual bytes; JSONB adds formatting whitespace.
    IF n NOT BETWEEN 1 AND 500 OR octet_length(p_payload::text)>524288 THEN RAISE EXCEPTION 'invalid_page' USING ERRCODE='22023'; END IF;
    FOR item IN SELECT * FROM jsonb_array_elements(p_payload->'points') LOOP
      SELECT (x->>'source_count')::integer INTO source_count FROM jsonb_array_elements(e.routes) x
        WHERE (x->>'route_uuid')::uuid=(item->>'route_uuid')::uuid;
      IF source_count IS NULL OR (item->>'point_index')::integer>=source_count THEN
        RAISE EXCEPTION 'invalid_point_index' USING ERRCODE='22023';
      END IF;
      SELECT * INTO prior FROM public.healthkit_workout_route_points WHERE user_id=p_user_id AND workout_uuid=p_workout_uuid
        AND export_uuid=p_export_uuid AND route_uuid=(item->>'route_uuid')::uuid AND point_index=(item->>'point_index')::integer;
      IF prior.route_uuid IS NOT NULL THEN
        IF ROW(prior.timestamp,prior.latitude,prior.longitude,prior.altitude,prior.horizontal_accuracy,prior.vertical_accuracy)
          IS DISTINCT FROM ROW((item->>'timestamp')::timestamptz,(item->>'latitude')::float8,(item->>'longitude')::float8,
            (item->>'altitude')::float8,(item->>'horizontal_accuracy')::float8,(item->>'vertical_accuracy')::float8) THEN
          RAISE EXCEPTION 'point_conflict' USING ERRCODE='22023';
        END IF;
      ELSE
        INSERT INTO public.healthkit_workout_route_points VALUES(p_user_id,p_workout_uuid,p_export_uuid,
          (item->>'route_uuid')::uuid,(item->>'point_index')::integer,(item->>'timestamp')::timestamptz,
          (item->>'latitude')::float8,(item->>'longitude')::float8,(item->>'altitude')::float8,
          (item->>'horizontal_accuracy')::float8,(item->>'vertical_accuracy')::float8);
      END IF;
    END LOOP;
    SELECT count(*) INTO actual FROM public.healthkit_workout_route_points
      WHERE user_id=p_user_id AND workout_uuid=p_workout_uuid AND export_uuid=p_export_uuid;
    RETURN jsonb_build_object('observed_count',actual);
  ELSIF p_operation='finalize' THEN
    IF jsonb_typeof(p_payload->'invalid_counts') IS DISTINCT FROM 'array' OR
       jsonb_array_length(p_payload->'invalid_counts')<>jsonb_array_length(e.routes) THEN
      RAISE EXCEPTION 'count_mismatch' USING ERRCODE='22023';
    END IF;
    SELECT COALESCE(jsonb_agg(jsonb_build_object('route_uuid',(x->>'route_uuid')::uuid,'invalid_count',(x->>'invalid_count')::integer)
      ORDER BY (x->>'route_uuid')::uuid),'[]'::jsonb) INTO counts FROM jsonb_array_elements(p_payload->'invalid_counts') x;
    FOR spec IN SELECT * FROM jsonb_array_elements(e.routes) LOOP
      SELECT count(*),max((x->>'invalid_count')::integer) INTO n,invalid_count FROM jsonb_array_elements(counts) x
        WHERE (x->>'route_uuid')::uuid=(spec->>'route_uuid')::uuid;
      SELECT count(*) INTO actual FROM public.healthkit_workout_route_points WHERE user_id=p_user_id AND workout_uuid=p_workout_uuid
        AND export_uuid=p_export_uuid AND route_uuid=(spec->>'route_uuid')::uuid;
      IF n<>1 OR invalid_count IS NULL OR invalid_count<0 OR actual+invalid_count<>(spec->>'source_count')::integer THEN
        RAISE EXCEPTION 'count_mismatch' USING ERRCODE='22023';
      END IF;
    END LOOP;
    IF e.completed_at IS NOT NULL AND e.invalid_counts<>counts THEN RAISE EXCEPTION 'revision_conflict' USING ERRCODE='22023'; END IF;
    IF EXISTS(SELECT 1 FROM public.healthkit_workout_route_exports WHERE user_id=p_user_id AND workout_uuid=p_workout_uuid
      AND is_current AND revision>e.revision) THEN RAISE EXCEPTION 'stale_revision' USING ERRCODE='22023'; END IF;
    UPDATE public.healthkit_workout_route_exports SET is_current=false WHERE user_id=p_user_id AND workout_uuid=p_workout_uuid
      AND is_current AND export_uuid<>p_export_uuid;
    UPDATE public.healthkit_workout_route_exports SET is_current=true,invalid_counts=counts,completed_at=COALESCE(completed_at,now())
      WHERE user_id=p_user_id AND workout_uuid=p_workout_uuid AND export_uuid=p_export_uuid;
    SELECT count(*) INTO actual FROM public.healthkit_workout_route_points
      WHERE user_id=p_user_id AND workout_uuid=p_workout_uuid AND export_uuid=p_export_uuid;
    RETURN jsonb_build_object('export_uuid',p_export_uuid,'complete',true,'coverage','observed_only',
      'observed_count',actual,'invalid_counts',counts);
  END IF;
  RAISE EXCEPTION 'invalid_operation' USING ERRCODE='22023';
END $$;
REVOKE ALL ON FUNCTION public.health4ai_workout_routes_v1(uuid,text,uuid,uuid,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.health4ai_workout_routes_v1(uuid,text,uuid,uuid,jsonb) TO service_role;
COMMIT;
