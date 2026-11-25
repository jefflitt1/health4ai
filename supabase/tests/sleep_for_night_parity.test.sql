-- Parity test: public.healthkit_sleep_for_night(user, night) == v_healthkit_sleep_nightly row.
-- LOCAL jgle-test-db ONLY. Run via supabase/tests/run_sleep_for_night_parity.sh, which rewrites
-- the public.* names in migration 014 into the scratch schema and strips its role grants.
-- The view below is the LIVE prod definition (pg_get_viewdef 2026-11-25), not 004's older text.
DROP SCHEMA IF EXISTS h4ai_parity CASCADE;
CREATE SCHEMA h4ai_parity;
SET search_path = h4ai_parity, pg_temp;

CREATE TABLE healthkit_metrics (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL, metric_type text NOT NULL, value float8, unit text,
  source_device text, started_at timestamptz NOT NULL, ended_at timestamptz,
  metadata jsonb, synced_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ON healthkit_metrics (user_id, metric_type, started_at DESC);

CREATE VIEW v_healthkit_sleep_nightly AS
 WITH sleep_candidates AS (
   SELECT user_id,
     date_trunc('day', (started_at AT TIME ZONE 'America/New_York') - interval '6 hours')::date AS night_date,
     source_device,
     CASE WHEN source_device ILIKE '%Oura%' THEN 1 WHEN source_device ILIKE '%Apple Watch%' THEN 2 ELSE 9 END AS source_priority,
     value, started_at, ended_at
   FROM healthkit_metrics
   WHERE metric_type = 'HKCategoryTypeIdentifierSleepAnalysis' AND value = ANY (ARRAY[3.0,4.0,5.0]::float8[])
     AND ended_at IS NOT NULL AND (source_device ILIKE '%Oura%' OR source_device ILIKE '%Apple Watch%')
 ), best_source_per_night AS (
   SELECT user_id, night_date, min(source_priority) AS best_priority FROM sleep_candidates GROUP BY user_id, night_date
 ), filtered AS (
   SELECT c.* FROM sleep_candidates c JOIN best_source_per_night b
     ON c.user_id = b.user_id AND c.night_date = b.night_date AND c.source_priority = b.best_priority
 )
 SELECT user_id, night_date,
   round(sum(extract(epoch FROM ended_at - started_at) / 3600.0), 2) AS sleep_hours,
   round(sum(CASE WHEN value = 4.0 THEN extract(epoch FROM ended_at - started_at) / 60.0 ELSE 0::numeric END), 1) AS deep_minutes,
   round(sum(CASE WHEN value = 5.0 THEN extract(epoch FROM ended_at - started_at) / 60.0 ELSE 0::numeric END), 1) AS rem_minutes,
   count(*) AS segment_count, min(source_device) AS sleep_source
 FROM filtered GROUP BY user_id, night_date;

-- @@FUNCTION@@ (the runner splices migration 014 here)

-- Synthetic data. local(x) = wall-clock time in America/New_York.
CREATE FUNCTION local(t text) RETURNS timestamptz LANGUAGE sql IMMUTABLE AS
  $$ SELECT t::timestamp AT TIME ZONE 'America/New_York' $$;

INSERT INTO healthkit_metrics (user_id, metric_type, value, source_device, started_at, ended_at)
-- Bulk: user A, 37-minute cadence around both DST nights; per-day source mix (both / watch-only / oura-only),
-- values cycle through filtered (0,1,2,6) and kept (3,4,5), every 11th row has NULL ended_at.
SELECT '00000000-0000-0000-0000-00000000000a'::uuid,
       'HKCategoryTypeIdentifierSleepAnalysis',
       (ARRAY[3,4,5,0,3,4,5,2,1,5,6])[1 + (n % 11)],
       CASE (d % 3)
         WHEN 0 THEN CASE WHEN n % 2 = 0 THEN 'Oura' ELSE 'Apple Watch' END   -- both: Oura must win
         WHEN 1 THEN 'Jeff''s Apple Watch'                                      -- watch only
         ELSE 'Oura Ring' END,
       s, CASE WHEN n % 11 = 10 THEN NULL ELSE s + ((10 + n % 50) || ' minutes')::interval END
FROM (SELECT n, d, s FROM (
        SELECT n, (n / 39) AS d, '2026-03-05 00:00'::timestamp AT TIME ZONE 'America/New_York' + (n * 37 || ' minutes')::interval AS s
        FROM generate_series(0, 360) n
        UNION ALL
        SELECT n, (n / 39) AS d, '2026-10-29 00:00'::timestamp AT TIME ZONE 'America/New_York' + (n * 37 || ' minutes')::interval AS s
        FROM generate_series(0, 360) n) x) y;

-- User C: Apple Watch only, same cadence and both DST ranges (watch-only nights over many days).
INSERT INTO healthkit_metrics (user_id, metric_type, value, source_device, started_at, ended_at)
SELECT '00000000-0000-0000-0000-00000000000c'::uuid, 'HKCategoryTypeIdentifierSleepAnalysis',
       (ARRAY[3,4,5,0,3])[1 + (n % 5)], 'Apple Watch', s, s + interval '25 minutes'
FROM (SELECT '2026-03-05 00:00'::timestamp AT TIME ZONE 'America/New_York' + (n * 61 || ' minutes')::interval AS s, n FROM generate_series(0, 200) n
      UNION ALL
      SELECT '2026-10-29 00:00'::timestamp AT TIME ZONE 'America/New_York' + (n * 61 || ' minutes')::interval, n FROM generate_series(0, 200) n) z;

-- Explicit boundary + edge segments (both users), both DST nights, one source each unless noted.
INSERT INTO healthkit_metrics (user_id, metric_type, value, source_device, started_at, ended_at)
SELECT u, 'HKCategoryTypeIdentifierSleepAnalysis', v, src, st, st + interval '30 minutes'
FROM (VALUES
  -- exactly 06:00 local starts the NEW night; 05:59:59 belongs to the previous one
  ('00000000-0000-0000-0000-00000000000a'::uuid, 4.0, 'Oura',        local('2026-03-08 06:00:00')),
  ('00000000-0000-0000-0000-00000000000a'::uuid, 5.0, 'Oura',        local('2026-03-08 05:59:59')),
  ('00000000-0000-0000-0000-00000000000a'::uuid, 3.0, 'Apple Watch', local('2026-03-09 06:00:00')),
  ('00000000-0000-0000-0000-00000000000a'::uuid, 3.0, 'Apple Watch', local('2026-03-09 05:59:59')),
  ('00000000-0000-0000-0000-00000000000a'::uuid, 4.0, 'Oura',        local('2026-11-01 06:00:00')),
  ('00000000-0000-0000-0000-00000000000a'::uuid, 5.0, 'Oura',        local('2026-11-01 05:59:59')),
  ('00000000-0000-0000-0000-00000000000a'::uuid, 5.0, 'Oura',        local('2026-11-02 06:00:00')),
  -- fall-back repeated hour 01:00-02:00 on 2026-11-01: both instants, EDT then EST
  ('00000000-0000-0000-0000-00000000000a'::uuid, 4.0, 'Oura',        '2026-11-01 05:30:00+00'),
  ('00000000-0000-0000-0000-00000000000a'::uuid, 3.0, 'Oura',        '2026-11-01 06:30:00+00'),
  -- spring-forward: instants straddling the 02:00 -> 03:00 gap on 2026-03-08
  ('00000000-0000-0000-0000-00000000000a'::uuid, 5.0, 'Apple Watch', '2026-03-08 06:59:00+00'),
  ('00000000-0000-0000-0000-00000000000a'::uuid, 5.0, 'Apple Watch', '2026-03-08 07:01:00+00'),
  -- user B: Apple Watch only, Oura with non-sleep value only (filtered), unknown source (filtered)
  ('00000000-0000-0000-0000-00000000000b'::uuid, 3.0, 'Apple Watch', local('2026-03-08 23:00')),
  ('00000000-0000-0000-0000-00000000000b'::uuid, 4.0, 'Apple Watch', local('2026-03-09 00:30')),
  ('00000000-0000-0000-0000-00000000000b'::uuid, 0.0, 'Oura',        local('2026-03-08 23:10')),
  ('00000000-0000-0000-0000-00000000000b'::uuid, 5.0, 'Fitbit',      local('2026-03-08 23:20')),
  ('00000000-0000-0000-0000-00000000000b'::uuid, 5.0, 'Oura',        local('2026-10-31 22:00')),
  ('00000000-0000-0000-0000-00000000000b'::uuid, 4.0, 'Oura',        local('2026-11-01 01:30')),
  ('00000000-0000-0000-0000-00000000000b'::uuid, 4.0, 'Oura',        '2026-11-01 06:15:00+00')
) t(u, v, src, st);
-- NULL ended_at (filtered) and a non-sleep metric type
INSERT INTO healthkit_metrics (user_id, metric_type, value, source_device, started_at, ended_at) VALUES
  ('00000000-0000-0000-0000-00000000000b', 'HKCategoryTypeIdentifierSleepAnalysis', 4.0, 'Oura', local('2026-11-05 01:00'), NULL),
  ('00000000-0000-0000-0000-00000000000b', 'HKQuantityTypeIdentifierHeartRate', 4.0, 'Oura', local('2026-11-05 02:00'), local('2026-11-05 02:30'));
ANALYZE healthkit_metrics;

-- Assertions. Every (user, night) over a window wider than the data, so empty nights are compared too.
CREATE TEMP TABLE keys AS
  SELECT u AS user_id, d::date AS night_date
  FROM unnest(ARRAY['00000000-0000-0000-0000-00000000000a','00000000-0000-0000-0000-00000000000b','00000000-0000-0000-0000-00000000000c']::uuid[]) u,
       (SELECT generate_series('2026-03-01'::date, '2026-03-20'::date, interval '1 day') UNION ALL SELECT generate_series('2026-10-25'::date, '2026-11-10'::date, interval '1 day')) g(d);

CREATE TEMP TABLE via_view AS
  SELECT k.user_id, k.night_date, v.sleep_hours, v.deep_minutes, v.rem_minutes, v.sleep_source
  FROM keys k LEFT JOIN v_healthkit_sleep_nightly v USING (user_id, night_date);
CREATE TEMP TABLE via_fn AS
  SELECT k.user_id, k.night_date, f.sleep_hours, f.deep_minutes, f.rem_minutes, f.sleep_source
  FROM keys k LEFT JOIN LATERAL healthkit_sleep_for_night(k.user_id, k.night_date) f ON true;

SELECT (SELECT count(*) FROM healthkit_metrics) AS rows_inserted,
       (SELECT count(*) FROM keys) AS keys_compared,
       (SELECT count(*) FROM via_view WHERE sleep_hours IS NOT NULL) AS nonempty_nights_in_view,
       (SELECT count(*) FROM via_view WHERE sleep_hours IS NULL) AS empty_nights,
       (SELECT count(*) FROM via_view WHERE sleep_source ILIKE '%Oura%') AS oura_nights,
       (SELECT count(*) FROM via_view WHERE sleep_source ILIKE '%Watch%') AS watch_nights,
       (SELECT count(*) FROM (SELECT * FROM via_view EXCEPT SELECT * FROM via_fn) a) AS only_in_view,
       (SELECT count(*) FROM (SELECT * FROM via_fn EXCEPT SELECT * FROM via_view) b) AS only_in_fn;

-- zero-row contract: function returns no row (not a NULL row) for an empty night
SELECT count(*) AS rows_for_empty_night FROM healthkit_sleep_for_night('00000000-0000-0000-0000-00000000000a', '2030-01-01');

DO $$
DECLARE nonempty int; bad int; n_oura int; n_watch int;
BEGIN
  SELECT count(*) INTO nonempty FROM via_view WHERE sleep_hours IS NOT NULL;
  SELECT count(*) INTO n_oura FROM via_view WHERE sleep_source ILIKE '%Oura%';
  SELECT count(*) INTO n_watch FROM via_view WHERE sleep_source ILIKE '%Watch%';
  SELECT count(*) INTO bad FROM ((SELECT * FROM via_view EXCEPT SELECT * FROM via_fn) UNION ALL (SELECT * FROM via_fn EXCEPT SELECT * FROM via_view)) z;
  IF nonempty < 20 OR n_oura = 0 OR n_watch = 0 THEN RAISE EXCEPTION 'VACUOUS: nonempty=%, oura=%, watch=%', nonempty, n_oura, n_watch; END IF;
  IF bad <> 0 THEN RAISE EXCEPTION 'PARITY FAIL: % differing (user,night) rows', bad; END IF;
  IF EXISTS (SELECT 1 FROM healthkit_sleep_for_night('00000000-0000-0000-0000-00000000000a', '2030-01-01')) THEN
    RAISE EXCEPTION 'empty night returned a row'; END IF;
  RAISE NOTICE 'PASS: function == view; rows=% keys=% nonempty=% empty=% oura_nights=% watch_nights=% diff=0', (SELECT count(*) FROM healthkit_metrics), (SELECT count(*) FROM keys), nonempty, (SELECT count(*) FROM keys) - nonempty, n_oura, n_watch;
END $$;

DROP SCHEMA h4ai_parity CASCADE;
