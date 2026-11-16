"""Negative controls require no PostgreSQL connection or third-party imports."""
import unittest

from workout_proof_guards import EXPECTED, expected_mutation_failure, local_connection


class ProofGuards(unittest.TestCase):
    def test_explicit_loopback(self):
        for host, address in [('localhost', '127.0.0.1'), ('127.0.0.1', '127.0.0.1'), ('::1', '::1')]:
            self.assertEqual(local_connection({'host': host}, {})['hostaddr'], address)

    def test_remote_or_indirect_dsn_rejected(self):
        for source in [{}, {'host': 'example.com'}, {'host': '127.0.0.1,example.com'},
                       {'host': 'localhost', 'hostaddr': '203.0.113.1'},
                       {'host': 'localhost', 'hostaddr': '127.0.0.1,203.0.113.1'},
                       {'host': 'localhost', 'hostaddr': 'remote.invalid'},
                       {'host': 'localhost', 'service': 'production'},
                       {'host': 'localhost', 'servicefile': '/tmp/pg_service.conf'}]:
            with self.subTest(source=source), self.assertRaises(ValueError):
                local_connection(source, {})

    def test_environment_overrides_rejected(self):
        for key in ['PGHOST', 'PGHOSTADDR', 'PGSERVICE', 'PGSERVICEFILE', 'PGPORT', 'PGDATABASE', 'PGOPTIONS']:
            with self.subTest(key=key), self.assertRaises(ValueError):
                local_connection({'host': 'localhost'}, {key: 'override'})

    def test_exact_mutation_failure_only(self):
        for name, (marker, assertion) in EXPECTED.items():
            output = marker + '\nTraceback (most recent call last):\nAssertionError: ' + assertion + '\n'
            self.assertTrue(expected_mutation_failure(name, 1, output))
            for code, bad in [(0, output), (2, output), (1, output.replace(marker, '')),
                              (1, output.replace(assertion, 'connection failure')),
                              (1, output + 'cleanup failed\n'),
                              (1, output + output),
                              (1, 'OperationalError: connection refused\n')]:
                with self.subTest(name=name, code=code, output=bad):
                    self.assertFalse(expected_mutation_failure(name, code, bad))


if __name__ == '__main__':
    unittest.main()
