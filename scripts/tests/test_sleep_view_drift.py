"""D1396 drift check: the repo's migrations must rebuild v_healthkit_sleep_nightly exactly as it is live.

Uses only a disposable database inside the local jgle-test-db container (never prod). The migration
history is not a fresh-database path (see supabase/config.toml), so this replays only the migrations
that create or replace the view, in numeric order, over the production-shaped healthkit_metrics table
from docs/destructive-paths-review-2026-09-13-schema.sql, then compares pg_get_viewdef() with the
committed snapshot of the live definition.

Run: python3 scripts/tests/test_sleep_view_drift.py [--migrations-dir DIR]
Exit 1 when the definitions differ. Refresh the snapshot only from a live read:
  SELECT pg_get_viewdef('public.v_healthkit_sleep_nightly'::regclass, true)
"""
import argparse
from pathlib import Path
import re
import subprocess
import sys
import uuid

ROOT = Path(__file__).resolve().parents[2]
SNAPSHOT = ROOT / "supabase/tests/snapshots/v_healthkit_sleep_nightly.live.txt"
SCHEMA = ROOT / "docs/destructive-paths-review-2026-09-13-schema.sql"
VIEW_DDL = re.compile(
    r"^\s*(CREATE\s+(OR\s+REPLACE\s+)?|ALTER\s+|DROP\s+)VIEW\s+(IF\s+EXISTS\s+)?public\.v_healthkit_sleep_nightly\b",
    re.I | re.M)
DOCKER = ["docker", "exec", "-i", "jgle-test-db"]


def run(args, sql=None):
    result = subprocess.run(args, input=sql, text=True, capture_output=True)
    if result.returncode:
        raise RuntimeError(result.stderr)
    return result.stdout


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--migrations-dir", type=Path, default=ROOT / "supabase/migrations")
    args = parser.parse_args()
    chain = sorted(p for p in args.migrations_dir.glob("*.sql") if VIEW_DDL.search(p.read_text()))
    assert chain, "no migration defines v_healthkit_sleep_nightly"
    print("migrations replayed:", ", ".join(p.name for p in chain))
    database = "h4a_sleepview_" + uuid.uuid4().hex[:12]
    run(DOCKER + ["createdb", "-U", "postgres", database])
    psql = DOCKER + ["psql", "-U", "postgres", "-d", database, "-XAtq", "-v", "ON_ERROR_STOP=1"]
    try:
        run(psql, SCHEMA.read_text())
        for path in chain:
            run(psql, path.read_text())
        built = run(psql, "SELECT pg_get_viewdef('public.v_healthkit_sleep_nightly'::regclass, true);")
        columns = run(psql, "SELECT string_agg(attname||':'||format_type(atttypid,atttypmod), ',' ORDER BY attnum) "
                            "FROM pg_attribute WHERE attrelid='public.v_healthkit_sleep_nightly'::regclass AND attnum>0;")
    finally:
        run(DOCKER + ["dropdb", "-U", "postgres", "--if-exists", database])
    live = SNAPSHOT.read_text()
    if built.rstrip("\n") != live.rstrip("\n"):
        import difflib
        sys.stdout.writelines(difflib.unified_diff(
            live.splitlines(True), built.splitlines(True), "live snapshot", "repo rebuild"))
        print(f"FAIL: repo rebuild differs from live snapshot (columns: {columns.strip()})")
        return 1
    print(f"PASS: repo rebuild equals live snapshot byte-for-byte (columns: {columns.strip()})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
