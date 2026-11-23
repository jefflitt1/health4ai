"""Guard the missing-CI regression: green unrelated jobs must not stand in for Netlify."""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def assert_netlify_wiring(text):
    required = (
        r'^  pull_request:\s*$',
        r'^    name: Netlify backend tests$',
        r'^        working-directory: backends/netlify$',
        r'^          pnpm install --frozen-lockfile$',
        r'^        run: pnpm run typecheck$',
        r'^        run: pnpm test$',
    )
    for pattern in required:
        if not re.search(pattern, text, re.MULTILINE):
            raise AssertionError(f'Netlify CI missing required wiring: {pattern}')
    if re.search(r'^\s*(?:if|paths|paths-ignore|continue-on-error):', text, re.MULTILINE):
        raise AssertionError('Required Netlify job must not be conditional or tolerate failure')


class NetlifyWiring(unittest.TestCase):
    def test_required_suite_is_wired(self):
        assert_netlify_wiring((ROOT / '.github/workflows/netlify-tests.yml').read_text())

    def test_prior_workflow_does_not_pass(self):
        with self.assertRaises(AssertionError):
            assert_netlify_wiring((ROOT / '.github/workflows/migration-grants.yml').read_text())

    def test_omitted_or_masked_tests_fail(self):
        text = (ROOT / '.github/workflows/netlify-tests.yml').read_text()
        for broken in (
            text.replace('run: pnpm test', 'run: echo skipped'),
            text.replace('run: pnpm test', 'run: pnpm test || true'),
            text.replace('run: pnpm test', 'continue-on-error: true\n        run: pnpm test'),
            text.replace('name: Netlify backend tests', 'name: Netlify backend tests\n    if: false'),
        ):
            with self.subTest(broken=broken), self.assertRaises(AssertionError):
                assert_netlify_wiring(broken)


if __name__ == '__main__':
    unittest.main()
