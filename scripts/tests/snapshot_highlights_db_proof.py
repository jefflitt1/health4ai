"""Synthetic snapshot-cap and unit proof in a rollback-only LOCAL PostgreSQL schema."""
import os
from pathlib import Path
import sys
import uuid

import psycopg2
from psycopg2.extensions import make_dsn, parse_dsn
from workout_proof_guards import local_connection


def main():
    source = local_connection(parse_dsn(os.environ['H4A_TEST_POSTGRES_URL']), os.environ)
    name = 'h4a_snapshot_' + uuid.uuid4().hex[:12]
    conn = psycopg2.connect(**source)
    try:
        os.environ['DATABASE_URL'] = make_dsn(**source)
        sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'mcp-server'))
        from health4ai import tools
        uid, other = str(uuid.uuid4()), str(uuid.uuid4())
        tools.current_user_id.set(uid)
        tools.TABLE = name + '.healthkit_metrics'
        with conn.cursor() as cur:
            cur.execute('CREATE SCHEMA ' + name)
            cur.execute(f'''CREATE TABLE {tools.TABLE} (
                user_id uuid, metric_type text, value double precision, unit text,
                started_at timestamptz, ended_at timestamptz, source_device text, metadata jsonb)''')
            start, end = tools._local_day_bounds_utc(tools._today_local().isoformat(),
                                                   tools._today_local().isoformat())
            cur.execute(f'''INSERT INTO {tools.TABLE}(user_id,metric_type,value,unit,started_at)
                SELECT %s,%s,1,'kcal',%s::timestamptz FROM generate_series(1,1100)''',
                        (uid, tools.ACTIVE_ENERGY, start))
            rows = [(uid, tools.HRV, 42, 'ms', start), (uid, tools.STEPS, 0, 'count', start),
                    (uid, tools.WEIGHT, 999, 'furlong', start),
                    (uid, tools.WEIGHT, 160, 'lb', start),
                    (other, tools.ACTIVE_ENERGY, 9999, 'kcal', start),
                    (uid, tools.ACTIVE_ENERGY, 9999, 'kcal', end)]
            cur.executemany(f'''INSERT INTO {tools.TABLE}
                (user_id,metric_type,value,unit,started_at) VALUES(%s,%s,%s,%s,%s)''', rows)
        # Exercise the real SQL on one borrowed test connection: the local relay
        # serializes connections. Connection creation itself is unchanged code.
        class BorrowedConnection:
            def cursor(self, **kwargs):
                return conn.cursor(**kwargs)

            def close(self):
                """The fixture owns this connection and closes it in finally."""
                return None

        tools._connect = BorrowedConnection
        result = tools.get_daily_snapshot()
        assert result['truncated'] and result['total_records'] == 1000
        assert result['highlights']['active_energy_cal'] == 1100
        assert result['highlights']['steps'] == 0
        assert result['highlights']['hrv_sdnn_ms'] == 42
        assert result['highlights']['weight_kg'] == 72.57
        assert {tools.HRV, tools.STEPS, tools.WEIGHT}.issubset(result['metrics_present'])
        print('PASS: capped1000 listing; uncapped1100 total; zero steps; hidden HRV; '
              'convertible lb after unknown unit; user isolation; exclusive end boundary')
        with conn.cursor() as cur:
            cur.execute('SELECT count(*) FROM ' + tools.TABLE)
            assert cur.fetchone()[0] == 1106
        print('PASS: all1106 synthetic rows retained; read-only tool changed no data')
    finally:
        conn.rollback()
        with conn.cursor() as cur:
            cur.execute('SELECT count(*) FROM pg_namespace WHERE nspname=%s', (name,))
            assert cur.fetchone()[0] == 0
        conn.close()
        print('PASS: transaction rolled back; isolated schema absent; shared service retained')


if __name__ == '__main__':
    main()
