"""check-migration-grants.py: each rule fails the migration it should and passes the one it should not.

Inline cases go through analyse() (rule logic); the CLI cases at the bottom exercise the baseline,
exit codes and the zero-files guard end to end. The two fixture files are the demonstration pair.
"""
import importlib.util
import os
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCRIPT = Path(os.environ.get("CMG_SCRIPT", (HERE / ".." / "check-migration-grants.py").resolve()))  # env = mutation-test seam
FIX = HERE / "fixtures" / "migration-grants"
TEMPLATE = (HERE / ".." / "migration-templates" / "public_table.sql").resolve()
spec = importlib.util.spec_from_file_location("cmg", SCRIPT)
cmg = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cmg)

T = "create table public.t (id uuid primary key);\nalter table public.t enable row level security;\n"
CASES = {
    # name: (sql, expected rule set)
    "service_role only": (T + "grant select, insert, update, delete on public.t to service_role;", set()),
    "authenticated + service_role": (T + "grant select, update on table public.t to authenticated; grant all on public.t to service_role;", set()),
    "anon with reason": (T + "-- anon-ok: public read surface for the site\ngrant select on public.t to anon;\ngrant select on public.t to service_role;", set()),
    "anon reason inline": (T + "grant select on public.t to anon, service_role; -- anon-ok: public read surface", set()),
    "closed by design": ("-- data-api: none (reached only through SECURITY DEFINER RPCs)\ncreate table public.t (id int);\nalter table public.t enable row level security;", set()),
    "bulk service_role grant": (T + "grant all on all tables in schema public to service_role;", set()),
    "identity needs no sequence grant": ("create table public.t (id bigint generated always as identity primary key);\nalter table public.t enable row level security;\ngrant select, insert on public.t to service_role;", set()),
    "serial with sequence grant": ("create table public.t (id bigserial primary key);\nalter table public.t enable row level security;\ngrant select, insert on public.t to service_role;\ngrant usage on sequence public.t_id_seq to service_role;", set()),
    "serial with bulk sequence grant": ("create table public.t (id serial primary key);\nalter table public.t enable row level security;\ngrant insert on public.t to service_role;\ngrant usage on all sequences in schema public to service_role;", set()),
    "other schema is not guarded": ("create table grand_directory.t (id int);", set()),
    "search_path moves unqualified names": ("set search_path to iv_directory;\ncreate table t (id int);", set()),
    "temp and partition child": ("create temp table a (id int);\ncreate table public.p1 partition of public.p for values from (1) to (2);", set()),
    "create or replace view with grant": ("create or replace view public.v as select 1;\ngrant select on public.v to service_role;", set()),
    "anon reason covers its own grant only, write included": (T + "-- anon-ok: public signup form, insert only\ngrant insert on public.t to anon;\ngrant select on public.t to service_role;", set()),
    "anon grant with reason then revoked write": (T + "-- anon-ok: read surface\ngrant select on public.t to anon;\ngrant insert on public.t to anon;\nrevoke insert on public.t from anon;\ngrant select on public.t to service_role;", set()),
    "upper-case default privileges to service_role": ("ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO service_role;", set()),
    "set schema into public, with rls and grant": ("create table staging.t (id int);\nalter table staging.t set schema public;\nalter table public.t enable row level security;\ngrant select on public.t to service_role;", set()),
    "plpgsql select into a variable is not a table": ("do $$ declare v int; begin select 1 into v from pg_class; end $$;", set()),
    "rename keeps the relation's grant": ("create table public.t (id int);\nalter table public.t enable row level security;\nalter table public.t rename to u;\ngrant select on public.u to service_role;", set()),
    "rename column is not a table rename": (T + "alter table public.t rename column id to uid;\ngrant select on public.t to service_role;", set()),
    "serial8 with sequence grant": ("create table public.t (id serial8 primary key);\nalter table public.t enable row level security;\ngrant select, insert on public.t to service_role;\ngrant usage on sequence public.t_id_seq to service_role;", set()),
    "serial on a 60-char table name: sequence name is truncated like Postgres": (f"create table public.{'t' * 60} (id serial primary key);\nalter table public.{'t' * 60} enable row level security;\ngrant insert on public.{'t' * 60} to service_role;\ngrant usage on sequence public.{'t' * 56}_id_seq to service_role;", set()),
    "nested block comment hides its contents": ("/* outer /* inner */ create table public.ghost (id int); */\nselect 1;", set()),
    "revoke grant option for does not remove the privilege": (T + "grant select on public.t to service_role;\nrevoke grant option for select on public.t from service_role;", set()),
    "grant then revoke anon": (T + "grant select on public.t to anon, service_role;\nrevoke all on public.t from anon;", set()),
    "text in strings, comments and bodies is ignored": ("-- create table public.ghost (id int);\n/* create table public.ghost2 (id int); */\nselect 'create table public.ghost3 (id int)';\ncreate function public.f() returns void language sql as $$ select 'grant all on all tables in schema public to anon' $$;", set()),
    "view with grant": ("create view public.v as select 1;\ngrant select on public.v to service_role;", set()),
    "quoted identifiers": ('create table public."My Table" (id int);\nalter table public."My Table" enable row level security;\ngrant select on public."My Table" to service_role;', set()),
    "DO block with create and grant": ("do $m$\nbegin\ncreate table public.t (id int);\nalter table public.t enable row level security;\ngrant select on public.t to service_role;\nend\n$m$;", set()),
    "DO block without grant": ("do $m$\nbegin\ncreate table public.t (id int);\nalter table public.t enable row level security;\nend $m$;", {"G001"}),
    "EXECUTE $ddl$ and EXECUTE string inside DO": ("do $$\nbegin\n  execute $ddl$ create table public.t (id int) $ddl$;\n  execute 'alter table public.t enable row level security';\n  execute 'grant select on public.t to service_role';\nend $$;", set()),
    "EXECUTE string without grant": ("do $$ begin execute 'create table public.t (id int)'; end $$;", {"G001", "G002"}),
    "IF NOT EXISTS ... THEN create": ("do $$ begin if not exists (select 1 from pg_class where relname = 't') then create table public.t (id int); end if; end $$;", {"G001", "G002"}),
    "bulk anon grant inside DO": ("do $$ begin grant select on all tables in schema public to anon; end $$;", {"G004"}),
    "DDL inside a function body is not this migration's create": ("create function public.mk() returns void language plpgsql as $$ begin create table public.t (id int); end $$;", set()),
    "no grant": ("create table public.t (id int);\nalter table public.t enable row level security;", {"G001"}),
    "unqualified name is public": ("create table t (id int);\nalter table t enable row level security;", {"G001"}),
    "grant names a different table": (T + "grant select on public.other to service_role;", {"G001"}),
    "schema usage is not a table grant": (T + "grant usage on schema public to service_role;", {"G001"}),
    "annotation without a reason": ("-- data-api: none\ncreate table public.t (id int);\nalter table public.t enable row level security;", {"G001"}),
    "grant then revoke everything": (T + "grant select on public.t to service_role;\nrevoke all on public.t from service_role;", {"G001"}),
    "view without grant": ("create view public.v as select 1;", {"G001"}),
    "materialized view without grant": ("create materialized view public.v as select 1;", {"G001"}),
    "if not exists still counts": ("create table if not exists public.t (id int);\nalter table public.t enable row level security;", {"G001"}),
    "no rls": ("create table public.t (id int);\ngrant select on public.t to service_role;", {"G002"}),
    "anon without reason": (T + "grant select on public.t to anon;\ngrant select on public.t to service_role;", {"G003"}),
    "anon write without reason": (T + "grant select, insert on public.t to anon, service_role;", {"G003"}),
    "grant to PUBLIC": (T + "grant select on public.t to public;\ngrant select on public.t to service_role;", {"G003"}),
    "reason comment too far above": (T + "-- anon-ok: public read surface\n\nselect 1;\ngrant select on public.t to anon, service_role;", {"G003"}),
    "bulk grant to anon": (T + "grant select on all tables in schema public to anon;\ngrant select on public.t to service_role;", {"G003", "G004"}),
    "bulk grant to authenticated": ("grant all on all tables in schema public to authenticated;", {"G004"}),
    "bulk sequences to authenticated": ("grant usage on all sequences in schema public to authenticated;", {"G004"}),
    "default privileges to anon": ("alter default privileges for role postgres in schema public\n  grant select, insert, update, delete on tables to anon, authenticated, service_role;", {"G004"}),
    "default privileges, no schema, to authenticated": ("alter default privileges grant select on tables to authenticated;", {"G004"}),
    "default privileges revoke is fine": ("alter default privileges for role postgres in schema public revoke select on tables from anon, authenticated, service_role;", set()),
    "default privileges to service_role is fine": ("alter default privileges for role postgres in schema public grant select on tables to service_role;", set()),
    "serial without sequence grant": ("create table public.t (id bigserial primary key);\nalter table public.t enable row level security;\ngrant select, insert on public.t to service_role;", {"G005"}),
    "two tables, one missing": (T + "grant select on public.t to service_role;\ncreate table public.u (id int);\nalter table public.u enable row level security;", {"G001"}),
    # --- independent review 2026-10-20: each of these passed (or failed) wrongly before the fix ---
    "create or replace view without grant is a new view": ("create or replace view public.v as select 1;", {"G001"}),
    "anon read reason does not cover a later anon write": (T + "-- anon-ok: public read surface\ngrant select on public.t to anon;\ngrant insert, update, delete on public.t to anon;\ngrant select on public.t to service_role;", {"G003"}),
    "anon read reason does not cover grant all": (T + "-- anon-ok: public read surface\ngrant select on public.t to anon;\ngrant all on public.t to anon;\ngrant select on public.t to service_role;", {"G003"}),
    "upper-case default privileges to anon": ("ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO anon;", {"G004"}),
    "search_path with $user first": ('set search_path = "$user", public;\ncreate table t (id int);\nalter table t enable row level security;', {"G001"}),
    "set schema moves a table into public": ("create table staging.t (id int);\nalter table staging.t set schema public;", {"G001", "G002"}),
    "select into creates a public table": ("select * into public.t from other;", {"G001", "G002"}),
    "rename does not lose the relation": ("create table public.t (id int);\nalter table public.t rename to u;", {"G001", "G002"}),
    "serial4 without sequence grant": ("create table public.t (id serial4 primary key);\nalter table public.t enable row level security;\ngrant select, insert on public.t to service_role;", {"G005"}),
    "sequence SELECT alone does not satisfy serial": ("create table public.t (id serial primary key);\nalter table public.t enable row level security;\ngrant select, insert on public.t to service_role;\ngrant select on sequence public.t_id_seq to service_role;", {"G005"}),
    "sequence grant revoked again": ("create table public.t (id serial primary key);\nalter table public.t enable row level security;\ngrant select, insert on public.t to service_role;\ngrant usage on sequence public.t_id_seq to service_role;\nrevoke usage on sequence public.t_id_seq from service_role;", {"G005"}),
    "else'..\\' is not an E-string": ("select case when true then 'a' else'C:\\' end;\ncreate table public.t (id int);", {"G001", "G002"}),
    # --- independent review of #659, L1: relations the first version could not see ---
    "foreign table without grant (no RLS rule: foreign tables cannot have it)": ("create foreign table public.ft (id int) server s;", {"G001"}),
    "foreign table with grant": ("create foreign table public.ft (id int) server s;\ngrant select on public.ft to service_role;", set()),
    "foreign table closed by design": ("-- data-api: none (read only through a definer function)\ncreate foreign table public.ft (id int) server s;", set()),
    "foreign table if not exists": ("create foreign table if not exists public.ft (id int) server s;", {"G001"}),
    "foreign table in another schema is not guarded": ("create foreign table remote.ft (id int) server s;", set()),
    "foreign table moved into public": ("create foreign table remote.ft (id int) server s;\nalter foreign table remote.ft set schema public;", {"G001"}),
    "top-level unqualified select into is a table": ("select * into t from other;", {"G001", "G002"}),
    "top-level unqualified select into with rls and grant": ("select * into t from other;\nalter table t enable row level security;\ngrant select on t to service_role;", set()),
    "top-level unqualified select into follows search_path": ("set search_path to staging;\nselect * into t from other;", set()),
    "top-level select into temp is not a public relation": ("select * into temp t from other;\nselect * into temporary table u from other;", set()),
    "select into inside a DO block fills a plpgsql variable": ("do $$ declare t int; begin select count(*) into t from pg_class; end $$;", set()),
    "select into inside a function body fills a plpgsql variable": ("create function public.f() returns int language plpgsql as $$ declare n int; begin select 1 into n; return n; end $$;\ngrant execute on function public.f() to service_role;", set()),
}


class Rules(unittest.TestCase):
    def test_cases(self):
        for name, (sql, want) in CASES.items():
            with self.subTest(name):
                found, _, _ = cmg.analyse(sql, {"public"})
                self.assertEqual({r for _, _, r, _ in found}, want, found)

    def test_unresolvable_create_table_warns_instead_of_silently_passing(self):
        for sql in ("do $$ begin execute format('create table public.%I (id int)', 'x'); end $$;",
                    "create function public.mk() returns void language plpgsql as $$ begin create table public.x (id int); end $$;"):
            found, dyn, _ = cmg.analyse(sql, {"public"})
            self.assertEqual((found, len(dyn)), ([], 1), sql)

    def test_guarded_schema_is_configurable(self):
        found, _, n = cmg.analyse("create table grand_directory.t (id int);", {"grand_directory"})
        self.assertEqual((n, {r for _, _, r, _ in found}), (1, {"G001", "G002"}))

    def test_template_passes_with_placeholders_filled(self):
        text = TEMPLATE.read_text().replace("<table_name>", "example_widget")
        found, _, n = cmg.analyse(text, {"public"})
        self.assertEqual((n, found), (1, []), found)


class Cli(unittest.TestCase):
    def run_cli(self, *args, ci=False):
        # The lint prints ::error annotations when GITHUB_ACTIONS is set and plain `file:line:` lines otherwise.
        # Set it explicitly either way: the ambient value on the machine running the tests must not pick the format.
        env = {k: v for k, v in os.environ.items() if k != "GITHUB_ACTIONS"}
        if ci:
            env["GITHUB_ACTIONS"] = "true"
        p = subprocess.run([sys.executable, "-I", str(SCRIPT), *args], capture_output=True, text=True, env=env)
        return p.returncode, p.stdout + p.stderr

    def test_fixture_pair_fails_without_grant_and_passes_with_it(self):
        rc, out = self.run_cli(str(FIX / "missing_grant.sql"))
        self.assertEqual(rc, 1, out)
        self.assertIn("G001 public.example_widget", out)
        rc, out = self.run_cli(str(FIX / "with_grant.sql"))
        self.assertEqual(rc, 0, out)
        self.assertIn("1 relation(s) in public, 0 finding(s)", out)

    def test_output_format_follows_github_actions_not_the_machine_running_the_tests(self):
        bad = str(FIX / "missing_grant.sql")
        rc, out = self.run_cli(bad)
        self.assertEqual(rc, 1, out)
        self.assertRegex(out, r"missing_grant\.sql:\d+: G001 public\.example_widget")
        self.assertNotIn("::error", out)
        rc, out = self.run_cli(bad, ci=True)
        self.assertEqual(rc, 1, out)
        self.assertRegex(out, r"::error file=\S*missing_grant\.sql,line=\d+::G001 public\.example_widget")

    def test_exclude_skips_tests_fixtures_and_rollbacks(self):
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            (d / "tests").mkdir()
            (d / "tests" / "t.sql").write_text("create table public.a (id int);\n")
            (d / "003_x.rollback.sql").write_text("create table public.b (id int);\n")
            (d / "004_ok.sql").write_text((FIX / "with_grant.sql").read_text())
            self.assertEqual(self.run_cli(str(d))[0], 1)
            rc, out = self.run_cli("--exclude", "*/tests/*", "--exclude", "*.rollback.sql", str(d))
            self.assertEqual(rc, 0, out)
            self.assertIn("1 file(s)", out)

    def test_zero_files_is_an_error_not_a_pass(self):
        rc, out = self.run_cli("/nonexistent/dir/*.sql")
        self.assertEqual(rc, 2, out)

    def test_one_misspelled_path_among_good_ones_is_an_error(self):
        rc, out = self.run_cli(str(FIX / "with_grant.sql"), str(FIX / "nonexistent_dir"))
        self.assertEqual(rc, 2, out)
        self.assertIn("nonexistent_dir", out)

    def test_write_baseline_requires_a_baseline_file(self):
        self.assertEqual(self.run_cli("--write-baseline", str(FIX / "with_grant.sql"))[0], 2)

    def test_second_blanket_grant_in_a_baselined_file_is_still_caught(self):
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            f, base = d / "001.sql", d / "baseline.txt"
            f.write_text("grant select on all tables in schema public to authenticated;\n")
            self.assertEqual(self.run_cli("--root", str(d), "--baseline", str(base), "--write-baseline", str(d))[0], 0)
            self.assertEqual(self.run_cli("--root", str(d), "--baseline", str(base), str(d))[0], 0)
            f.write_text("grant select on all tables in schema public to authenticated;\ngrant all on all tables in schema public to anon;\n")
            rc, out = self.run_cli("--root", str(d), "--baseline", str(base), str(d))
            self.assertEqual(rc, 1, out)
            self.assertIn("to anon", out)

    def test_baseline_grandfathers_only_listed_findings(self):
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            old, new = d / "001_old.sql", d / "002_new.sql"
            old.write_text("create table public.legacy (id int);\n")
            base = d / "baseline.txt"
            rc, out = self.run_cli("--root", str(d), "--baseline", str(base), "--write-baseline", str(d))
            self.assertEqual(rc, 0, out)
            self.assertIn("001_old.sql|public.legacy|G001", base.read_text())
            self.assertEqual(self.run_cli("--root", str(d), "--baseline", str(base), str(d))[0], 0)
            new.write_text("create table public.fresh (id int);\n")
            rc, out = self.run_cli("--root", str(d), "--baseline", str(base), str(d))
            self.assertEqual(rc, 1, out)
            self.assertIn("002_new.sql:1: G001 public.fresh", out)
            self.assertNotIn("legacy", out.split("check-migration-grants:")[0])
            old.write_text("create table public.legacy (id int);\ncreate table public.legacy2 (id int);\n")
            rc, out = self.run_cli("--root", str(d), "--baseline", str(base), str(old))
            self.assertEqual(rc, 1, "a new table in a baselined file is still caught: " + out)
            old.write_text("create table public.legacy (id int);\nalter table public.legacy enable row level security;\ngrant select on public.legacy to service_role;\n")
            rc, out = self.run_cli("--root", str(d), "--baseline", str(base), str(old))
            self.assertEqual(rc, 0, out)
            self.assertIn("2 stale baseline line(s)", out)

    def seed(self, d, **files):
        for name, text in files.items():
            (d / name).write_text(text)
        base = d / "baseline.txt"
        self.assertEqual(self.run_cli("--root", str(d), "--baseline", str(base), "--write-baseline", str(d))[0], 0)
        return base

    def test_editing_a_baselined_file_ends_its_grandfathering(self):
        # review of #659, M3: the key was file|relation|rule, so rewriting a baselined file to recreate the same
        # relation with no grant stayed green. Each entry now carries a hash of the file's content.
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            old = d / "legacy.sql"
            base = self.seed(d, **{"legacy.sql": "create table public.legacy (id int);\n"})
            lines = [x for x in base.read_text().splitlines() if not x.startswith("#")]
            self.assertTrue(lines and all(re.fullmatch(r"legacy\.sql\|public\.legacy\|G00[12]\|[0-9a-f]{12}", x) for x in lines), lines)
            self.assertEqual(self.run_cli("--root", str(d), "--baseline", str(base), str(d))[0], 0)
            old.write_text("drop table public.legacy;\ncreate table public.legacy (id int, extra text);\n")
            rc, out = self.run_cli("--root", str(d), "--baseline", str(base), str(d))
            self.assertEqual(rc, 1, out)
            self.assertIn("G001 public.legacy", out)
            self.assertIn("file changed", out)

    def test_reseeding_an_existing_baseline_never_adds_a_key(self):
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            base = self.seed(d, **{"001_old.sql": "create table public.legacy (id int);\n"})
            before = base.read_text()
            reseed = ("--root", str(d), "--baseline", str(base), "--write-baseline")
            (d / "002_new.sql").write_text("create table public.fresh (id int);\n")
            rc, out = self.run_cli(*reseed, str(d))
            self.assertEqual(rc, 2, out)
            self.assertIn("refusing to grow", out)
            self.assertEqual(base.read_text(), before)
            (d / "002_new.sql").unlink()
            (d / "001_old.sql").write_text("-- reworded\ncreate table public.legacy (id int);\n")  # the hash changes: that is a new key
            self.assertEqual(self.run_cli(*reseed, str(d))[0], 2)
            self.assertEqual(self.run_cli(*reseed, "--allow-additions", str(d))[0], 0)  # deliberate, and visible in the diff
            self.assertNotEqual(base.read_text(), before)
            (d / "001_old.sql").write_text("create table public.legacy (id int);\nalter table public.legacy enable row level security;\ngrant select on public.legacy to service_role;\n")
            self.assertEqual(self.run_cli(*reseed, str(d))[0], 0)  # shrinking never needs the flag
            self.assertEqual([x for x in base.read_text().splitlines() if not x.startswith("#")], [])

    def test_stale_baseline_lines_are_counted_only_under_the_linted_paths(self):
        # review of #659, M1: linting one registry must not report every other registry's baseline as stale.
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            for sub in ("a", "b"):
                (d / sub).mkdir()
                (d / sub / "001.sql").write_text("create table public.t (id int);\n")
            base = d / "baseline.txt"
            self.assertEqual(self.run_cli("--root", str(d), "--baseline", str(base), "--write-baseline", str(d))[0], 0)
            rc, out = self.run_cli("--root", str(d), "--baseline", str(base), str(d / "a"))
            self.assertEqual(rc, 0, out)
            self.assertIn("0 stale baseline line(s)", out)
            (d / "b" / "001.sql").unlink()
            rc, out = self.run_cli("--root", str(d), "--baseline", str(base), str(d))
            self.assertIn("2 stale baseline line(s)", out)  # a deleted baselined file is still reported when its directory is linted


if __name__ == "__main__":
    unittest.main()
