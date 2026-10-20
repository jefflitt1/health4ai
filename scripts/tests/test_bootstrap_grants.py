"""The schema customers install must work on a Supabase project that no longer auto-grants Data API access.

Two guards, both about web/public/schema.sql (the single file https://health4.ai/schema.sql serves and the
setup docs tell people to run):

1. It is exactly what scripts/build_schema_sql.sh builds from supabase/bootstrap/001 + 002. The grants lint
   (scripts/lint-migration-grants.sh) reads schema.sql rather than the two halves, because 001 creates the
   tables and 002 grants them; only the concatenation is the unit that either works or does not.
2. Applied to a throwaway local Supabase Postgres in the post-2026-10-30 state (default grants revoked),
   service_role can ingest, anon can only add a waitlist row, authenticated sees only its own rows. A copy of
   the schema without the service_role grant must be DENIED, or the test is not detecting the bug.

(2) needs docker and the local image; it skips without them (CI) and is not deleted. Opt out: H4AI_DOCKER_PROOF=0.
"""
import os
import shutil
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCHEMA = ROOT / "web" / "public" / "schema.sql"
SERVICE_GRANT = "GRANT SELECT, INSERT, UPDATE, DELETE ON public.healthkit_metrics TO service_role;"
IMAGE = "public.ecr.aws/supabase/postgres:17.6.1.003"
NAME = f"h4ai-grants-proof-{os.getpid()}"
UID = "11111111-1111-1111-1111-111111111111"
OTHER = "22222222-2222-2222-2222-222222222222"
# Verbatim from https://supabase.com/docs/guides/api/securing-your-api (existing-project opt-in snippet).
OCT_30 = """
alter default privileges for role postgres in schema public revoke select, insert, update, delete on tables from anon, authenticated, service_role;
alter default privileges for role postgres in schema public revoke execute on functions from anon, authenticated, service_role;
alter default privileges for role postgres in schema public revoke usage, select on sequences from anon, authenticated, service_role;
"""
# Empties `public` (tables, then the functions that are not extension members) and the test user.
RESET = """do $$ declare r record; begin
  for r in select tablename from pg_tables where schemaname = 'public' loop execute format('drop table public.%I cascade', r.tablename); end loop;
  for r in select p.oid::regprocedure as f from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')
  loop execute 'drop function ' || r.f || ' cascade'; end loop;
end $$;
delete from auth.users;"""
UPSERT = ("insert into public.healthkit_metrics (user_id, metric_type, value, unit, source_device, started_at) "
          "values ('{u}', 'steps', {v}, 'count', 'Watch', '2026-01-01T10:15:00Z') "
          "on conflict (user_id, metric_type, source_device, started_at) do update set value = excluded.value;")
MERGED = ("select deleted_count, written_count from public.health4ai_replace_merged_hours('{u}', "
          '\'[{{"metric_type":"steps","value":900,"unit":"count","started_at":"2026-01-01T10:00:00Z",'
          '"ended_at":"2026-01-01T11:00:00Z","metadata":null}}]\'::jsonb);')
ADD_USER = f"\ninsert into auth.users (id) values ('{UID}');"


def docker(*args, sql=None):
    p = subprocess.run(["docker", *args], input=sql, capture_output=True, text=True)
    return p.returncode, p.stdout + p.stderr


def psql(sql):
    return docker("exec", "-i", "-e", "PGPASSWORD=proofpw", NAME, "psql", "-h", "localhost", "-U", "postgres",
                  "-d", "postgres", "-v", "ON_ERROR_STOP=1", "-At", "-f", "-", sql=sql)


def last_line(out):
    return out.strip().splitlines()[-1]


class SchemaSqlIsBuiltFromBootstrap(unittest.TestCase):
    def test_committed_schema_sql_equals_a_fresh_build(self):
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            (d / "scripts").mkdir()
            (d / "web" / "public").mkdir(parents=True)
            shutil.copy(ROOT / "scripts" / "build_schema_sql.sh", d / "scripts")
            shutil.copytree(ROOT / "supabase" / "bootstrap", d / "supabase" / "bootstrap")
            p = subprocess.run(["bash", str(d / "scripts" / "build_schema_sql.sh")], capture_output=True, text=True)
            self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
            built = (d / "web" / "public" / "schema.sql").read_text()
        self.assertEqual(built, SCHEMA.read_text(), "run scripts/build_schema_sql.sh and commit web/public/schema.sql")


@unittest.skipUnless(os.environ.get("H4AI_DOCKER_PROOF") != "0"
                     and subprocess.run(["docker", "image", "inspect", IMAGE], capture_output=True).returncode == 0,
                     f"needs docker and the local image {IMAGE}")
class OnSupabasePostgresAfterOct30(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        try:
            rc, out = docker("run", "-d", "--name", NAME, "-e", "POSTGRES_PASSWORD=proofpw", IMAGE)
            assert rc == 0, out
            for _ in range(60):
                if psql("select 1;")[0] == 0:
                    break
                time.sleep(2)
            schema = SCHEMA.read_text()
            mutant = schema.replace(SERVICE_GRANT, "")
            assert mutant != schema, "service_role grant line not found; update SERVICE_GRANT with the schema"
            # The post-change state first, then the schema WITHOUT the service_role grant (to prove the harness
            # can see the bug), then the same database is emptied and the real schema applied.
            assert psql(OCT_30)[0] == 0
            rc, out = psql(mutant + ADD_USER)
            assert rc == 0, out
            cls.mutant = psql(f"set role service_role; {UPSERT.format(u=UID, v=1)}")
            assert psql(RESET)[0] == 0
            rc, out = psql(schema + ADD_USER)
            assert rc == 0, out
        except BaseException:  # tearDownClass does not run when setUpClass raises
            docker("rm", "-f", NAME)
            raise

    @classmethod
    def tearDownClass(cls):
        docker("rm", "-f", NAME)

    def setUp(self):  # every case starts from empty tables, so test order cannot matter
        self.assertEqual(psql("delete from public.healthkit_metrics; delete from public.health4ai_waitlist;")[0], 0)

    def test_service_role_can_ingest_and_replace_merged_hours(self):
        rc, out = psql(f"set role service_role; {UPSERT.format(u=UID, v=100)} {UPSERT.format(u=UID, v=250)} "
                       "select count(*) || ':' || max(value) from public.healthkit_metrics;")
        self.assertEqual((rc, last_line(out)), (0, "1:250"), out)  # upserted twice: one row, updated in place
        rc, out = psql(f"set role service_role; {MERGED.format(u=UID)}")
        self.assertEqual((rc, last_line(out)), (0, "1|1"), out)  # deleted the per-device row, wrote the merged one

    def test_the_same_schema_minus_the_service_role_grant_is_denied(self):
        rc, out = self.mutant
        self.assertNotEqual(rc, 0)
        self.assertIn("permission denied for table healthkit_metrics", out)

    def test_anon_may_only_add_a_waitlist_row(self):
        ok = "set role anon; insert into public.health4ai_waitlist (email, consent_testflight, consent_source) values ('A@Example.com', true, 'web');"
        self.assertEqual(psql(ok)[0], 0)
        self.assertEqual(psql("select email from public.health4ai_waitlist;")[1].strip(), "a@example.com")  # stored, normalised
        for bad in ("insert into public.health4ai_waitlist (email, invite_status) values ('b@example.com', 'invited')",
                    "select email from public.health4ai_waitlist",
                    "select count(*) from public.healthkit_metrics",
                    UPSERT.format(u=UID, v=3).rstrip(";")):
            rc, out = psql(f"set role anon; {bad};")
            self.assertNotEqual(rc, 0, bad)
            self.assertIn("permission denied", out, bad)

    def test_authenticated_reads_and_deletes_only_its_own_rows(self):
        self.assertEqual(psql(UPSERT.format(u=UID, v=7))[0], 0)
        # This image's auth.uid() reads the per-claim setting; hosted Supabase also reads request.jwt.claims.
        jwt = "set role authenticated; select set_config('request.jwt.claim.sub', '%s', false);"
        rc, out = psql(jwt % UID + " select count(*) from public.healthkit_metrics;")
        self.assertEqual((rc, last_line(out)), (0, "1"), out)
        rc, out = psql(jwt % UID + " " + UPSERT.format(u=UID, v=9))
        self.assertNotEqual(rc, 0)
        self.assertIn("permission denied for table healthkit_metrics", out)
        rc, out = psql(jwt % OTHER + " select count(*) from public.healthkit_metrics;")
        self.assertEqual((rc, last_line(out)), (0, "0"), out)


if __name__ == "__main__":
    unittest.main()
