"""Real optional-contract/MCP proof using a unique database on LOCAL Postgres only.

H4A_TEST_POSTGRES_URL must point to localhost; no production fallback.
Run with the jgle-test-db URL supplied privately in the environment.
"""
import json
import os
from pathlib import Path
import sys
import threading
import time
import uuid

import psycopg2
from psycopg2.extensions import parse_dsn, make_dsn
from psycopg2.extras import Json
from workout_proof_guards import local_connection

ROOT = Path(__file__).resolve().parents[2]
UID, OTHER, WORKOUT, SAMPLE = [str(uuid.uuid4()) for _ in range(4)]
TYPE = 'HKQuantityTypeIdentifierHeartRate'


def main():
    source = local_connection(parse_dsn(os.environ['H4A_TEST_POSTGRES_URL']), os.environ)
    name = 'h4a_workout_' + uuid.uuid4().hex[:12]
    admin = psycopg2.connect(**source)
    admin.autocommit = True
    with admin.cursor() as cur:
        cur.execute('CREATE DATABASE ' + name)
    admin.close()
    target = dict(source, dbname=name)
    conn = None
    passed = 0

    def sql(statement, params=()):
        with conn.cursor() as cur:
            cur.execute(statement, params or None)
            return cur.fetchall() if cur.description else None

    def check(value, message):
        nonlocal passed
        assert value, message
        passed += 1
        print('PASS', message)

    def denied(fn, message):
        try:
            fn()
        except psycopg2.Error:
            check(True, message)
        else:
            raise AssertionError(message)

    def rpc(operation, revision=None, payload=None, user=UID, workout=WORKOUT):
        return sql('SELECT public.health4ai_workout_details_v1(%s,%s,%s,%s,%s)',
                   (user, operation, workout, revision, Json(payload or {})))[0][0]

    def begin(user=UID):
        revision = str(uuid.uuid4())
        rpc('begin', revision, {'query_types': [TYPE]}, user)
        return revision

    sample = {'sample_uuid': SAMPLE, 'metric_type': TYPE, 'value': 80, 'unit': 'count/min',
              'source_device': 'fixture', 'started_at': '2026-11-16T10:00:00Z',
              'ended_at': '2026-11-16T10:00:01Z'}
    try:
        conn = psycopg2.connect(**target)
        conn.autocommit = True
        sql('CREATE SCHEMA auth; CREATE TABLE auth.users(id uuid PRIMARY KEY)')
        for role in ('anon', 'authenticated', 'service_role'):
            if not sql('SELECT 1 FROM pg_roles WHERE rolname=%s', (role,)):
                sql('CREATE ROLE ' + role)
        sql('INSERT INTO auth.users VALUES(%s),(%s)', (UID, OTHER))
        schema = (ROOT / 'supabase/optional/workout-details-v1.sql').read_text()
        if os.environ.get('H4A_WORKOUT_MUTANT') == 'missing_count_guard':
            guard = "IF actual<>n THEN RAISE EXCEPTION 'count_mismatch' USING ERRCODE='22023'; END IF;"
            assert guard in schema
            schema = schema.replace(guard, '')
        elif os.environ.get('H4A_WORKOUT_MUTANT') == 'jsonb_wire_cap':
            assert '>524288' in schema
            schema = schema.replace('>524288', '>262144')
        sql(schema)
        for role in ('anon', 'authenticated'):
            sql('SET ROLE ' + role)
            denied(lambda: sql('SELECT * FROM public.healthkit_workout_exports'), role + ' cannot read headers')
            denied(lambda: rpc('capabilities'), role + ' cannot invoke writer')
            sql('RESET ROLE')
        sql('SET ROLE service_role')
        check(rpc('capabilities')['capabilities'] == ['workout_details_v1'], 'ready capability')
        denied(lambda: sql('DELETE FROM public.healthkit_workout_exports'), 'service cannot bypass RPC')
        first = begin()
        check(rpc('page', first, {'samples': [sample]})['observed_count'] == 1, 'first sample stored')
        check(rpc('page', first, {'samples': [sample]})['observed_count'] == 1, 'page retry deduplicates UUID')
        changed = dict(sample, value=90)
        denied(lambda: rpc('page', first, {'samples': [changed]}), 'conflicting retry rejected')
        denied(lambda: rpc('finalize', first, {'observed_count': 2}), 'partial count cannot finalize')
        check(sql('SELECT count(*) FROM public.healthkit_workout_exports WHERE is_current')[0][0] == 0,
              'partial revision invisible')
        rpc('finalize', first, {'observed_count': 1})
        check(rpc('finalize', first, {'observed_count': 1})['complete'], 'finalize retry idempotent')
        denied(lambda: rpc('page', first, {'samples': [changed]}), 'completed samples immutable')
        other_revision = begin(OTHER)
        rpc('page', other_revision, {'samples': [changed]}, OTHER)
        rpc('finalize', other_revision, {'observed_count': 1}, OTHER)
        check(sql('SELECT count(*) FROM public.healthkit_workout_samples')[0][0] == 2,
              'same sample/workout UUID isolated across tenants')
        denied(lambda: rpc('page', first, {'samples': [sample]}, OTHER), 'cannot cross tenant revision')
        second, third = begin(), begin()
        for revision in (second, third):
            rpc('page', revision, {'samples': [sample]})
        check(sql('SELECT export_uuid::text FROM public.healthkit_workout_exports WHERE user_id=%s AND is_current',
                  (UID,))[0][0] == first, 'new partial revision preserves old snapshot')
        rpc('finalize', third, {'observed_count': 1})
        denied(lambda: rpc('finalize', second, {'observed_count': 1}), 'older late completion rejected')
        bad = begin()
        for field, value in [('value', 'NaN'), ('ended_at', '2020-01-01T00:00:00Z'),
                             ('unit', ''), ('metric_type', 'HKQuantityTypeIdentifierStepCount')]:
            invalid = dict(sample, **{field: value})
            denied(lambda: rpc('page', bad, {'samples': [invalid]}), 'invalid sample ' + field)
        check(sql('SELECT count(*) FROM public.healthkit_workout_samples WHERE export_uuid=%s', (bad,))[0][0] == 0,
              'invalid pages rolled back')
        # Finalization must wait for an in-flight page, not publish a partial view.
        concurrent = begin()
        rpc('page', concurrent, {'samples': [sample]})
        result = {}
        ready = threading.Event()
        def finish():
            worker = psycopg2.connect(**target)
            try:
                result['pid'] = worker.get_backend_pid()
                ready.set()
                with worker, worker.cursor() as cur:
                    cur.execute('SELECT public.health4ai_workout_details_v1(%s,%s,%s,%s,%s)',
                                (UID, 'finalize', WORKOUT, concurrent, Json({'observed_count': 2})))
                    result['response'] = cur.fetchone()[0]
            except Exception as error:
                result['error'] = type(error).__name__
            finally:
                worker.close()
        conn.autocommit = False
        sql('SELECT pg_advisory_xact_lock(hashtextextended(%s,0))', (UID,))
        thread = threading.Thread(target=finish)
        thread.start()
        try:
            assert ready.wait(5)
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                if sql('SELECT count(*) FROM pg_locks WHERE pid=%s AND NOT granted', (result['pid'],))[0][0]:
                    break
                time.sleep(0.02)
            else:
                raise AssertionError('finalizer did not wait on page lock')
            check('response' not in result, 'finalizer waits behind active page transaction')
            rpc('page', concurrent, {'samples': [dict(sample, sample_uuid=str(uuid.uuid4()))]})
            conn.commit()
        finally:
            conn.rollback()
            conn.autocommit = True
            thread.join(10)
        check(not thread.is_alive() and result.get('response', {}).get('observed_count') == 2,
              'finalizer sees committed page count after lock release')
        # Full MCP consumer against the same real isolated database.
        os.environ.update(DATABASE_URL=make_dsn(**target), HEALTHKIT_USER_ID=UID,
                          HEALTH4AI_WORKOUT_DETAILS_ENABLED='true')
        sys.path.insert(0, str(ROOT / 'mcp-server'))
        from health4ai import tools
        from health4ai.workout_details import get_workout_details
        tools.current_user_id.set(UID)
        result = get_workout_details(WORKOUT)
        check(result['samples'][0]['value'] == 80 and result['observed_count'] == 2,
              'MCP returns exact own snapshot without other tenant value')
        paged = begin()
        second_sample = dict(sample, sample_uuid=str(uuid.uuid4()))
        rpc('page', paged, {'samples': [sample, second_sample]})
        rpc('finalize', paged, {'observed_count': 2})
        page = get_workout_details(WORKOUT, limit=1)
        check(bool(page['next_cursor']) and len(page['samples']) == 1, 'MCP bounded first page')
        end = get_workout_details(WORKOUT, cursor=page['next_cursor'], limit=1)
        check(end['next_cursor'] is None and end['samples'][0]['sample_uuid'] != page['samples'][0]['sample_uuid'],
              'MCP deterministic nonduplicating second page')
        tools.current_user_id.set(OTHER)
        try:
            get_workout_details(WORKOUT, cursor=page['next_cursor'])
        except ValueError:
            check(True, 'MCP rejects cursor from other tenant')
        else:
            raise AssertionError('cross-tenant cursor accepted')
        tools.current_user_id.set(UID)
        empty = begin()
        rpc('finalize', empty, {'observed_count': 0})
        check(get_workout_details(WORKOUT, cursor=page['next_cursor'])['status'] == 'snapshot_replaced',
              'MCP rejects cursor after revision replacement')
        check(get_workout_details(WORKOUT)['coverage'] == 'observed_only', 'empty never means fully authorized')
        cadence = str(uuid.uuid4())
        rpc('begin', cadence, {'query_types': ['HKQuantityTypeIdentifierStepCount', TYPE]})
        steps = dict(sample, sample_uuid=str(uuid.uuid4()), metric_type='HKQuantityTypeIdentifierStepCount',
                     unit='count', value=3)
        rpc('page', cadence, {'samples': [steps, sample]})
        rpc('finalize', cadence, {'observed_count': 2})
        annotated = get_workout_details(WORKOUT)['samples']
        step_result = next(row for row in annotated if row['metric_type'].endswith('StepCount'))
        heart_result = next(row for row in annotated if row['metric_type'] == TYPE)
        check(step_result['derived_cadence']['value'] == 180 and
              step_result['derived_cadence']['workout_average'] is None,
              'actual MCP wires interval-only step cadence from exact associated sample')
        check('derived_cadence' not in heart_result, 'MCP does not add cadence to heart rate')
        rpc('delete_all', user=UID, workout=None)
        check(sql('SELECT count(*) FROM public.healthkit_workout_samples WHERE user_id=%s', (UID,))[0][0] == 0,
              'erase cascades all own revisions/samples')
        check(sql('SELECT count(*) FROM public.healthkit_workout_samples WHERE user_id=%s', (OTHER,))[0][0] == 1,
              'erase preserves other tenant')
        check(get_workout_details(WORKOUT)['status'] == 'snapshot_unavailable', 'MCP deleted snapshot unavailable')
        os.environ['HEALTH4AI_WORKOUT_DETAILS_ENABLED'] = 'false'
        check(get_workout_details('invalid')['status'] == 'feature_disabled', 'MCP disabled before DB access')
        # PostgreSQL's JSONB whitespace must not reject a valid near-limit HTTP page.
        budget_workout, budget_export = str(uuid.uuid4()), str(uuid.uuid4())
        rpc('begin', budget_export, {'query_types': [TYPE]}, workout=budget_workout)
        batch = [dict(sample, sample_uuid=str(uuid.uuid4()), unit='u' * 64) for _ in range(500)]
        selected = None
        for length in range(1, 257):
            payload = {'operation': 'page', 'workout_uuid': budget_workout, 'export_uuid': budget_export,
                       'samples': [dict(row, source_device='x' * length) for row in batch]}
            if len(json.dumps(payload, separators=(',', ':')).encode()) <= 262144:
                selected = payload
        assert selected is not None
        check(sql('SELECT octet_length(%s::jsonb::text)', (Json(selected),))[0][0] > 262144,
              'boundary fixture expands beyond HTTP cap only after JSONB serialization')
        try:
            stored = rpc('page', budget_export, selected, workout=budget_workout)
        except psycopg2.errors.InvalidParameterValue as error:
            if error.diag.message_primary != 'invalid_page':
                raise
            raise AssertionError('valid near-256KiB wire page rejected by JSONB cap') from None
        check(stored['observed_count'] == 500,
              'valid near-256KiB wire page survives JSONB formatting overhead')
        rpc('delete', workout=budget_workout)
        from workout_route_db_proof import exercise_routes
        exercise_routes(sql, check, denied, UID, OTHER, WORKOUT)
        print(f'{passed} assertions PASS; real local PostgreSQL and MCP')
    finally:
        if conn is not None:
            conn.close()
        admin = psycopg2.connect(**source)
        admin.autocommit = True
        with admin.cursor() as cur:
            cur.execute('DROP DATABASE ' + name + ' WITH (FORCE)')
        admin.close()


if __name__ == '__main__':
    main()
