"""Exercise the actual verifier without network; reject secrets in child argv/output."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(os.environ.get("VERIFY_DEPLOY_SCRIPT", Path(__file__).with_name("verify-deploy.sh")))
SECRET = "SETUP_FIXTURE_SECRET"
KEY = "h4a_FIXTURE_DEVICE_KEY"


class VerifierSecrets(unittest.TestCase):
    def run_verifier(self, fail_issue=False, fail_setup=False):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            # Both curl and the JSON parser are child processes: neither may receive a key in argv.
            for name in ("curl", "python3"):
                wrapper = root / name
                wrapper.write_text(f"#!{sys.executable}\n" + '''
import json, os, pathlib, sys
root = pathlib.Path(os.environ["VERIFY_FIXTURE_ROOT"])
if any(secret in arg for secret in ("SETUP_FIXTURE_SECRET", "h4a_FIXTURE_DEVICE_KEY") for arg in sys.argv):
    (root / "argv-leak").write_text("credential reached child argv")
    sys.exit(91)
if pathlib.Path(sys.argv[0]).name == "python3":
    os.execv(os.environ["VERIFY_REAL_PYTHON"], [os.environ["VERIFY_REAL_PYTHON"], *sys.argv[1:]])
counter = root / "requests"
n = int(counter.read_text()) if counter.exists() else 0
counter.write_text(str(n + 1))
# Validate that private descriptors actually deliver the expected header to curl.
headers = []
for i, arg in enumerate(sys.argv):
    if arg == "-H":
        value = sys.argv[i + 1]
        headers.append(pathlib.Path(value[1:]).read_text() if value.startswith("@") else value)
if sys.argv[-1].endswith("/revoke"):
    assert "X-Setup-Secret: SETUP_FIXTURE_SECRET" in headers
    (root / "revoked").write_text("yes")
    print("\\n204", end="")
    sys.exit(0)
if n in (1, 2):
    assert "X-Setup-Secret: SETUP_FIXTURE_SECRET" in headers
if n in (4, 5, 6, 8):
    assert "Authorization: Bearer h4a_FIXTURE_DEVICE_KEY" in headers
responses = [('{"error":"Wrong setup secret"}',403), ('{"person_id":"fixture"}',200),
 ('{"key":"h4a_FIXTURE_DEVICE_KEY","id":"fixture-key"}',201),
 ('{"error":"Missing Authorization header"}',401),
 ('{"inserted":0,"capabilities":["merged_hours_v1"]}',200),
 ('{"inserted":2}',200), ('{"replaced":2}',200), ('',204),
 ('{"error":"Unauthorized"}',401), ('',204)]
body, status = responses[n]
if n == 2 and os.environ.get("VERIFY_FAIL_ISSUE") == "1":
    status = 500
if n == 0 and os.environ.get("VERIFY_FAIL_SETUP") == "1":
    status = 200
print(body + "\\n" + str(status), end="")
''')
                wrapper.chmod(0o700)
            env = dict(os.environ, PATH=str(root) + os.pathsep + os.environ["PATH"],
                       HEALTH4AI_SETUP_SECRET=SECRET, VERIFY_FIXTURE_ROOT=str(root),
                       VERIFY_REAL_PYTHON=sys.executable, VERIFY_FAIL_ISSUE=str(int(fail_issue)),
                       VERIFY_FAIL_SETUP=str(int(fail_setup)))
            result = subprocess.run(["bash", str(SCRIPT), "https://fixture.invalid"],
                                    env=env, capture_output=True, text=True)
            output = result.stdout + result.stderr
            self.assertFalse((root / "argv-leak").exists(), "credential reached child argv")
            self.assertNotIn(SECRET, output)
            self.assertNotIn(KEY, output)
            requests = int((root / "requests").read_text())
            if fail_issue or result.returncode == 0:
                self.assertTrue((root / "revoked").exists(), "issued key was not revoked")
            return result.returncode, requests, output

    def test_success_uses_private_headers_and_stdin(self):
        status, requests, output = self.run_verifier()
        self.assertEqual(status, 0, output)
        self.assertEqual(requests, 10)  # Includes final cleanup revocation.

    def test_failure_does_not_print_key_bearing_response(self):
        status, requests, output = self.run_verifier(fail_issue=True)
        self.assertNotEqual(status, 0)
        self.assertEqual(requests, 4)  # Failed issuance response still gets cleanup by id.
        self.assertIn("FAIL issue a Device key", output)

    def test_failed_setup_never_issues_key(self):
        status, requests, _ = self.run_verifier(fail_setup=True)
        self.assertNotEqual(status, 0)
        self.assertEqual(requests, 2)


if __name__ == "__main__":
    unittest.main()
