"""Wiring guard: the wrapper, the committed baseline and the CI workflow must really run the lint.

A lint nobody runs is not a guard. These fail if the wrapper stops reading the registries, the baseline is
emptied, or a workflow loses the step.
"""
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = (HERE / "../..").resolve()
FIX = HERE / "fixtures" / "migration-grants"
WRAPPER = ROOT / "scripts" / "lint-migration-grants.sh"
WORKFLOWS = [".github/workflows/migration-grants.yml"]


def socket_only_waits(text):
    """The pg_isready waits that do not go over TCP.

    The postgres image first runs a setup server that listens only on the Unix socket, stops it, then
    starts the real one. A socket check can pass against the setup server, and the next step then
    finds no server. Only the real server listens on 127.0.0.1.
    """
    return [c for c in re.findall(r"pg_isready[^\n]*", text) if "-h 127.0.0.1" not in c]


class Wiring(unittest.TestCase):
    def run_wrapper(self, *extra):
        p = subprocess.run([str(WRAPPER), *extra], capture_output=True, text=True, cwd=ROOT)
        return p.returncode, p.stdout + p.stderr

    def test_wrapper_passes_on_the_committed_baseline(self):
        rc, out = self.run_wrapper()
        self.assertEqual(rc, 0, out)
        self.assertRegex(out, r"[1-9]\d* file\(s\), [1-9]\d* relation\(s\)")  # non-vacuous: it really read the registries

    def test_wrapper_fails_a_new_migration_without_grant_and_passes_one_with_it(self):
        with tempfile.TemporaryDirectory() as d:
            bad, good = Path(d) / "9990_bad.sql", Path(d) / "9991_good.sql"
            bad.write_text((FIX / "missing_grant.sql").read_text())
            good.write_text((FIX / "with_grant.sql").read_text())
            rc, out = self.run_wrapper(str(bad))
            self.assertEqual(rc, 1, out)
            self.assertIn("G001 public.example_widget", out)
            self.assertEqual(self.run_wrapper(str(good))[0], 0)

    def test_ci_runs_the_wrapper(self):
        for name in WORKFLOWS:
            self.assertIn("lint-migration-grants.sh", (ROOT / name).read_text(), name)

    def test_postgres_waits_reach_the_real_server(self):
        for name in WORKFLOWS:
            text = (ROOT / name).read_text()
            self.assertIn("pg_isready", text, name)
            self.assertEqual(socket_only_waits(text), [], name)

    def test_a_socket_wait_is_caught(self):
        self.assertEqual(socket_only_waits("if docker exec db pg_isready -U postgres; then exit 0; fi"),
                         ["pg_isready -U postgres; then exit 0; fi"])


if __name__ == "__main__":
    unittest.main()
