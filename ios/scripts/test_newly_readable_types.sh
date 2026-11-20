#!/usr/bin/env bash
# Off-device tests for which finished import types became readable after their sweep (GitHub #71)
# (Health4AI/NewlyReadableTypes.swift).
# Usage: ios/scripts/test_newly_readable_types.sh            # run the checks
#        ios/scripts/test_newly_readable_types.sh --mutants  # prove each guarded behaviour fails when broken
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../Health4AI/NewlyReadableTypes.swift"
TESTS="$HERE/NewlyReadableTypesTests.swift"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

run() { # $1 = NewlyReadableTypes.swift to test. Exit 2 = did not build (never a killed mutant).
  # Top-level test code is only legal in a file named main.swift.
  cp "$TESTS" "$WORK/main.swift"
  cp "$1" "$WORK/NewlyReadableTypes.swift"
  xcrun swiftc -O -o "$WORK/t" "$WORK/NewlyReadableTypes.swift" "$WORK/main.swift" 2>"$WORK/build.log" \
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
mutate "upgrade re-arms everything"    'guard trackingStarted else {' 'guard trackingStarted || true else {'
mutate "seen types probed again"       'completed.subtracting(seen)' 'completed'
mutate "unfinished types probed"       'completed.subtracting(seen)' 'completed.union(seen)'
mutate "probe outside candidates"      'let found = probed.intersection(candidates(completed: completed, seen: seen))' 'let found = probed'
mutate "rearmed marked seen early"     'return Decision(rearm: found, seen: seen)' 'return Decision(rearm: found, seen: seen.union(found))'
mutate "nothing ever re-armed"         'return Decision(rearm: found, seen: seen)' 'return Decision(rearm: [], seen: seen)'
mutate "seeding forgets data types"    'return Decision(rearm: [], seen: seen.union(found))' 'return Decision(rearm: [], seen: seen)'
[ "$survivors" -eq 0 ] && echo "ALL MUTANTS KILLED" || { echo "$survivors mutant(s) survived"; exit 1; }
