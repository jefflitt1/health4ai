"""Fail-closed connection and mutation controls for the local-only proof."""
import ipaddress
import os
from pathlib import Path
import subprocess
import sys


def local_connection(source, environment):
    if any(key.startswith('PG') for key in environment):
        raise ValueError('Explicit local DSN required; PG environment overrides forbidden')
    if 'service' in source or 'servicefile' in source:
        raise ValueError('PostgreSQL service indirection forbidden')
    host = source.get('host')
    if host not in ('127.0.0.1', 'localhost', '::1'):
        raise ValueError('LOCAL database only')
    address = source.get('hostaddr', '::1' if host == '::1' else '127.0.0.1')
    try:
        valid = ipaddress.ip_address(address).is_loopback
    except ValueError:
        valid = False
    if not valid:
        raise ValueError('LOCAL hostaddr only')
    return dict(source, hostaddr=address)


EXPECTED = {
    'missing_count_guard': ('PASS conflicting retry rejected', 'partial count cannot finalize'),
    'jsonb_wire_cap': ('PASS boundary fixture expands beyond HTTP cap only after JSONB serialization',
                       'valid near-256KiB wire page rejected by JSONB cap'),
}


def expected_mutation_failure(name, returncode, output):
    marker, assertion = EXPECTED[name]
    lines = output.rstrip().splitlines()
    return (returncode == 1 and marker in lines and bool(lines)
            and lines[-1] == 'AssertionError: ' + assertion
            and output.count('Traceback (most recent call last):') == 1)


def main():
    for name in EXPECTED:
        result = subprocess.run(
            [sys.executable, '-u', str(Path(__file__).with_name('workout_detail_db_proof.py'))],
            env=dict(os.environ, H4A_WORKOUT_MUTANT=name), text=True,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        if not expected_mutation_failure(name, result.returncode, result.stdout):
            print(result.stdout)
            raise SystemExit('Mutation failed for an unexpected reason: ' + name)
        print('PASS expected mutation assertion:', name)


if __name__ == '__main__':
    main()
