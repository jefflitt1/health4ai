-- D1396: record the LIVE definition of public.v_healthkit_sleep_nightly.
--
-- THIS MIGRATION RECORDS AN ALREADY-LIVE DEFINITION. It must not change prod behaviour: the body
-- below is `pg_get_viewdef('public.v_healthkit_sleep_nightly'::regclass, true)` read from the
-- production database (PostgreSQL 17.6, verified 2026-11-25), with only the
-- `CREATE OR REPLACE VIEW ... AS` prefix added. Applying it to prod is a no-op.
--
-- WHY: 004_sleep_nightly_view.sql drifted from prod. 004 is Oura-only, has no source priority and
-- no sleep_source column; the live view ranks Oura=1 / Apple Watch=2, keeps only the best source
-- per night, and returns sleep_source. A rebuild from the repo would silently change sleep numbers.
-- Same-named columns keep their order and types, and sleep_source is appended last, so
-- CREATE OR REPLACE is valid over 004's view.
--
-- One spelling difference: pg_get_viewdef prints the value filter as `= ANY (ARRAY[3.0, 4.0, 5.0]::double precision[])`,
-- and that printed text does not re-parse to the same stored tree (it comes back as per-element casts).
-- `= ANY (ARRAY[3.0, 4.0, 5.0])` is the source form that deparses to the live text, so it is written that
-- way (same predicate; the drift check proves the deparsed definition is identical).
--
-- Grants: live ACL is postgres (owner), service_role (all privileges) and hermes_worker (SELECT only);
-- anon and authenticated have none. CREATE OR REPLACE VIEW preserves existing grants, so prod keeps
-- exactly that. The one GRANT at the bottom (SELECT to service_role, a subset of what it already holds)
-- is a no-op on prod; it exists so the grants lint (G001) and a rebuild from the repo agree with live.
-- hermes_worker's grant is not recorded here (role is estate-specific, absent from a fresh project).
-- Guard: supabase/tests/run_sleep_view_drift_check.sh compares the view this chain builds with
-- supabase/tests/snapshots/v_healthkit_sleep_nightly.live.txt (the committed live definition).
-- Rollback: re-apply the 004 definition (drops sleep_source; do not do this without the consumers).

CREATE OR REPLACE VIEW public.v_healthkit_sleep_nightly AS
 WITH sleep_candidates AS (
         SELECT healthkit_metrics.user_id,
            date_trunc('day'::text, (healthkit_metrics.started_at AT TIME ZONE 'America/New_York'::text) - '06:00:00'::interval)::date AS night_date,
            healthkit_metrics.source_device,
                CASE
                    WHEN healthkit_metrics.source_device ~~* '%Oura%'::text THEN 1
                    WHEN healthkit_metrics.source_device ~~* '%Apple Watch%'::text THEN 2
                    ELSE 9
                END AS source_priority,
            healthkit_metrics.value,
            healthkit_metrics.started_at,
            healthkit_metrics.ended_at
           FROM healthkit_metrics
          WHERE healthkit_metrics.metric_type = 'HKCategoryTypeIdentifierSleepAnalysis'::text AND (healthkit_metrics.value = ANY (ARRAY[3.0, 4.0, 5.0])) AND healthkit_metrics.ended_at IS NOT NULL AND (healthkit_metrics.source_device ~~* '%Oura%'::text OR healthkit_metrics.source_device ~~* '%Apple Watch%'::text)
        ), best_source_per_night AS (
         SELECT sleep_candidates.user_id,
            sleep_candidates.night_date,
            min(sleep_candidates.source_priority) AS best_priority
           FROM sleep_candidates
          GROUP BY sleep_candidates.user_id, sleep_candidates.night_date
        ), filtered AS (
         SELECT c.user_id,
            c.night_date,
            c.source_device,
            c.source_priority,
            c.value,
            c.started_at,
            c.ended_at
           FROM sleep_candidates c
             JOIN best_source_per_night b ON c.user_id = b.user_id AND c.night_date = b.night_date AND c.source_priority = b.best_priority
        )
 SELECT user_id,
    night_date,
    round(sum(EXTRACT(epoch FROM ended_at - started_at) / 3600.0), 2) AS sleep_hours,
    round(sum(
        CASE
            WHEN value = 4.0::double precision THEN EXTRACT(epoch FROM ended_at - started_at) / 60.0
            ELSE 0::numeric
        END), 1) AS deep_minutes,
    round(sum(
        CASE
            WHEN value = 5.0::double precision THEN EXTRACT(epoch FROM ended_at - started_at) / 60.0
            ELSE 0::numeric
        END), 1) AS rem_minutes,
    count(*) AS segment_count,
    min(source_device) AS sleep_source
   FROM filtered
  GROUP BY user_id, night_date;

GRANT SELECT ON public.v_healthkit_sleep_nightly TO service_role;
