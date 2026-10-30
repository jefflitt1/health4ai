"""The scheduled summarizer must use the project's database connection.

This test runs without production credentials. It fails on the former Management
API implementation, which required a separately rotated account token at import.
"""

import importlib.util
import os
import sys
import types
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch


SCRIPT = Path(__file__).with_name("summarize_historical.py")


class SummarizeConnectionTests(unittest.TestCase):
    def load_script(self):
        fake_dotenv = types.ModuleType("dotenv")
        fake_dotenv.load_dotenv = lambda **_kwargs: None
        env = {
            "DATABASE_URL": "postgresql://example.invalid/health4ai",
            "HEALTHKIT_USER_ID": "00000000-0000-0000-0000-000000000001",
            "SUPABASE_URL": "https://example.supabase.co",
            "SUPABASE_SERVICE_ROLE_KEY": "test-only",
        }
        with patch.dict(os.environ, env, clear=True), patch.dict(sys.modules, {"dotenv": fake_dotenv}):
            spec = importlib.util.spec_from_file_location("summarize_under_test", SCRIPT)
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)
        return module

    def test_import_needs_no_management_token(self):
        module = self.load_script()
        self.assertTrue(callable(module.types_before))

    def test_type_discovery_uses_user_scoped_database_query(self):
        module = self.load_script()
        conn = MagicMock()
        cur = conn.cursor.return_value.__enter__.return_value
        cur.fetchall.return_value = [("HKQuantityTypeIdentifierStepCount",)]
        with patch.object(module, "connect", return_value=conn):
            self.assertEqual(module.types_before("2026-09-30"), ["HKQuantityTypeIdentifierStepCount"])
        self.assertIn("statement_timeout", cur.execute.call_args_list[0].args[0])
        query, params = cur.execute.call_args_list[1].args
        self.assertIn("user_id = %s", query)
        self.assertIn("started_at < %s::date", query)
        self.assertEqual(params, (module.USER_ID, "2026-09-30"))
        conn.close.assert_called_once()

    def test_compaction_is_parameterized_and_committed(self):
        module = self.load_script()
        conn = MagicMock()
        cur = conn.cursor.return_value.__enter__.return_value
        cur.fetchall.return_value = [{"mode": "recompute", "raw_rows": 0, "summary_rows": 3, "skipped_days": 0}]
        with patch.object(module, "connect", return_value=conn):
            result = module.summarize("HKQuantityTypeIdentifierStepCount", "2026-09-30")
        self.assertEqual(result[0]["summary_rows"], 3)
        self.assertIn("SET LOCAL statement_timeout", cur.execute.call_args_list[0].args[0])
        query, params = cur.execute.call_args_list[1].args
        self.assertIn("health4ai_compact_metric_v2(%s, %s, %s::date)", query)
        self.assertEqual(params, (module.USER_ID, "HKQuantityTypeIdentifierStepCount", "2026-09-30"))
        conn.__exit__.assert_called_once()
        conn.close.assert_called_once()

    def test_missing_function_result_rolls_back(self):
        module = self.load_script()
        conn = MagicMock()
        cur = conn.cursor.return_value.__enter__.return_value
        cur.fetchall.return_value = []
        with patch.object(module, "connect", return_value=conn):
            with self.assertRaisesRegex(RuntimeError, "invalid result"):
                module.summarize("HKQuantityTypeIdentifierStepCount", "2026-09-30")
        self.assertIsNotNone(conn.__exit__.call_args.args[0])


if __name__ == "__main__":
    unittest.main()
