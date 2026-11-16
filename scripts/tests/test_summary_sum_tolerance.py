"""Real PostgreSQL regression. Uses only a disposable DB in local jgle-test-db.

Run: python3 scripts/tests/test_summary_sum_tolerance.py [--baseline /path/to/live.sql]
A baseline run must fail the first precision assertion (red-before-green).
"""
import argparse
from pathlib import Path
import subprocess
import uuid

ROOT = Path(__file__).resolve().parents[2]
USER = "a0000000-0000-0000-0000-000000000001"
METRIC = "HKQuantityTypeIdentifierAppleStandTime"
CALL = f"public.health4ai_compact_metric_v2('{USER}','{METRIC}','2026-01-02')"
CHECK = f"public.health4ai_recompute_mismatches('{USER}','{METRIC}','2026-01-02')"


def command(args, sql=None):
    result = subprocess.run(args, input=sql, text=True, capture_output=True)
    if result.returncode:
        raise RuntimeError(result.stderr)
    return result.stdout.strip()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--baseline", type=Path)
    args = parser.parse_args()
    database = "h4a_precision_" + uuid.uuid4().hex[:12]
    base = ["docker", "exec", "-i", "jgle-test-db"]
    command(base + ["createdb", "-U", "postgres", database])
    psql = base + ["psql", "-U", "postgres", "-d", database, "-XAtq", "-v", "ON_ERROR_STOP=1"]
    passed = 0

    def sql(statement):
        return command(psql, statement)

    def expect(statement, expected, label):
        nonlocal passed
        actual = sql(statement)
        assert actual == expected, f"{label}: expected {expected}, got {actual}"
        passed += 1
        print(f"PASS {label}")

    try:
        sql((ROOT / "docs/destructive-paths-review-2026-09-13-schema.sql").read_text())
        source = args.baseline or ROOT / "supabase/migrations/013_summary_sum_tolerance.sql"
        sql(source.read_text())
        sql(f"""INSERT INTO healthkit_metrics
            (user_id,metric_type,value,unit,source_device,started_at) VALUES
            ('{USER}','{METRIC}',0.1,'min','HealthKit (all sources)','2026-01-01T12:00Z'),
            ('{USER}','{METRIC}',0.2,'min','HealthKit (all sources)','2026-01-01T13:00Z');""")
        expect(f"SELECT summary_rows FROM {CALL};", "1", "initial summary written")
        sql("UPDATE healthkit_daily_summaries SET sum_value=0.3;")
        expect(f"SELECT count(*) FROM {CHECK};", "0", "roundoff is not a mismatch")
        expect(f"SELECT summary_rows FROM {CALL};", "0", "roundoff does not rewrite summary")
        expect("SELECT count(*) FROM healthkit_metrics;", "2", "merged raw samples retained")
        for field, value in [("sum_value", "0.31"), ("sum_value", "NULL"),
                             ("sum_value", "'Infinity'::float8"),
                             ("sum_value", "'NaN'::float8"),
                             ("sample_count", "3"), ("min_value", "0.09"),
                             ("max_value", "0.21")]:
            sql(f"UPDATE healthkit_daily_summaries SET {field}={value};")
            expect(f"SELECT count(*) FROM {CHECK};", "1", f"detect {field}={value}")
            expect(f"SELECT summary_rows FROM {CALL};", "1", f"repair {field}={value}")
            expect(f"SELECT count(*) FROM {CHECK};", "0", "repair read-back")
        sql("DELETE FROM healthkit_daily_summaries;")
        expect(f"SELECT count(*) FROM {CHECK};", "1", "missing summary detected")
        expect(f"SELECT summary_rows FROM {CALL};", "1", "missing summary recreated")
        expect(f"SELECT summary_rows FROM {CALL};", "0", "repeat run is idempotent")
        expect("SELECT count(*) FROM healthkit_metrics;", "2", "raw retention final read-back")
        for value in ("'Infinity'::float8", "'-Infinity'::float8", "'NaN'::float8"):
            sql(f"UPDATE healthkit_metrics SET value={value};")
            expect(f"SELECT summary_rows FROM {CALL};", "1", f"repair raw change to {value}")
            expect(f"SELECT count(*) FROM {CHECK};", "0", f"equal {value} is not a mismatch")
            expect(f"SELECT summary_rows FROM {CALL};", "0", f"equal {value} is not rewritten")
            sql("UPDATE healthkit_daily_summaries SET sum_value=1;")
            expect(f"SELECT count(*) FROM {CHECK};", "1", f"unequal {value} detected")
            expect(f"SELECT summary_rows FROM {CALL};", "1", f"unequal {value} repaired")
        expect("SELECT has_function_privilege('anon', 'public.health4ai_compact_metric_v2(uuid,text,date,interval,text)', 'EXECUTE');", "f", "anon cannot run writer")
        expect("SELECT has_function_privilege('service_role', 'public.health4ai_recompute_mismatches(uuid,text,date,text)', 'EXECUTE');", "t", "service role can check")
        print(f"{passed} assertions passed; local database {database}")
    finally:
        command(base + ["dropdb", "-U", "postgres", database])


if __name__ == "__main__":
    main()
