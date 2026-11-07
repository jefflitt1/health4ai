#!/usr/bin/env bash
# Off-device tests for which database the HealthKit sync position belongs to
# (Health4AI/SyncPosition.swift).
# Usage: ios/scripts/test_sync_position.sh            # run the checks
#        ios/scripts/test_sync_position.sh --mutants  # prove each guarded behaviour fails when broken
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../Health4AI/SyncPosition.swift"
TESTS="$HERE/SyncPositionTests.swift"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

run() { # $1 = SyncPosition.swift to test. Exit 2 = did not build (never a killed mutant).
  # Top-level test code is only legal in a file named main.swift.
  cp "$TESTS" "$WORK/main.swift"
  cp "$1" "$WORK/SyncPosition.swift"
  xcrun swiftc -O -o "$WORK/t" "$WORK/SyncPosition.swift" "$WORK/main.swift" 2>"$WORK/build.log" \
    || { cat "$WORK/build.log"; return 2; }
  "$WORK/t"
}

if [ "${1:-}" != "--mutants" ]; then
  run "$SRC"
  exit $?
fi

# Each mutant breaks one behaviour; the suite must FAIL on every one.
mutate() { # name, old, new
  local name="$1" old="$2" new="$3"
  python3 - "$SRC" "$WORK/m.swift" "$old" "$new" <<'PY'
import sys
src, out, old, new = sys.argv[1:]
s = open(src).read()
assert s.count(old) == 1, f"mutant anchor not unique: {old!r}"
open(out, "w").write(s.replace(old, new))
PY
  local rc=0
  run "$WORK/m.swift" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq 0 ]; then echo "MUTANT SURVIVED: $name"; survivors=$((survivors+1))
  elif [ "$rc" -eq 2 ]; then echo "MUTANT DID NOT BUILD (invalid mutant, not a kill): $name"; survivors=$((survivors+1))
  else echo "mutant killed: $name"; fi
}
survivors=0
mutate "unrecorded always restarts"   'return !connectingIsSupabase' 'return true'
mutate "unrecorded never restarts"    'return !connectingIsSupabase' 'return false'
mutate "keyed by kind, not endpoint"  'return normalized(recorded) != normalized(endpoint)' 'return false'
mutate "raw strings compared"         'return normalized(recorded) != normalized(endpoint)' 'return recorded != endpoint'
mutate "host case not ignored"        'parts.host = parts.host?.lowercased()' ''
mutate "trailing slash not ignored"   'while value.hasSuffix("/") { value.removeLast() }' ''
mutate "whitespace not ignored"       'endpoint.trimmingCharacters(in: .whitespacesAndNewlines)' 'endpoint'
[ "$survivors" -eq 0 ] && echo "ALL MUTANTS KILLED" || { echo "$survivors mutant(s) survived"; exit 1; }
