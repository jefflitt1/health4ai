#!/usr/bin/env bash
# Off-device tests for the Google Sheets destination's pure logic (Health4AI/SheetsLogic.swift).
# Usage: ios/scripts/test_sheets_logic.sh            # run the checks
#        ios/scripts/test_sheets_logic.sh --mutants  # prove each guarded behaviour fails when broken
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../Health4AI/SheetsLogic.swift"
TESTS="$HERE/SheetsLogicTests.swift"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

run() { # $1 = logic file. Exit 2 = did not build (never counts as a killed mutant).
  # Top-level test code is only legal in a file named main.swift.
  cp "$TESTS" "$WORK/main.swift"
  cp "$1" "$WORK/SheetsLogic.swift"
  xcrun swiftc -O -D H4A_SHEETS -o "$WORK/t" "$WORK/SheetsLogic.swift" "$WORK/main.swift" 2>"$WORK/build.log" || { cat "$WORK/build.log"; return 2; }
  "$WORK/t"
}

if [ "${1:-}" != "--mutants" ]; then
  run "$SRC"
  exit $?
fi

# Each mutant breaks one behaviour; the suite must FAIL on every one.
mutate() { # name, python replacement (old, new)
  local name="$1" old="$2" new="$3"
  python3 - "$SRC" "$WORK/m.swift" "$old" "$new" <<'EOF'
import sys
src, out, old, new = sys.argv[1:]
s = open(src).read()
assert s.count(old) == 1, f"mutant anchor not unique: {old!r}"
open(out, "w").write(s.replace(old, new))
EOF
  local rc=0; run "$WORK/m.swift" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq 0 ]; then echo "MUTANT SURVIVED: $name"; survivors=$((survivors+1))
  elif [ "$rc" -eq 2 ]; then echo "MUTANT DID NOT BUILD (invalid mutant, not a kill): $name"; survivors=$((survivors+1))
  else echo "mutant killed: $name"; fi
}
survivors=0
mutate "sleep sums instead of union"  'if let cur = current, interval.start <= cur.end {' 'if false, let cur = current, interval.start <= cur.end {'
mutate "sleep not clipped"            '.compactMap { $0.intersection(with: window) }' '.compactMap { Optional($0) }'
mutate "window midnight not noon"     'bySettingHour: 12' 'bySettingHour: 0'
mutate "upsert row off by one"        'rowForDate[key] = i + 2' 'rowForDate[key] = i + 1'
mutate "upsert appends unsorted"      'for row in rows.sorted(by: { ($0.first ?? "") < ($1.first ?? "") }) {' 'for row in rows {'
mutate "missing data written as 0"    'guard let value, value.isFinite else { return "" }' 'guard let value, value.isFinite else { return "0" }'
mutate "pkce challenge not hashed"    'base64url(Data(SHA256.hash(data: Data(verifier.utf8))))' 'base64url(Data(verifier.utf8))'
mutate "days step by 86400s"          'day = calendar.date(byAdding: .day, value: 1, to: day)!' 'day = day.addingTimeInterval(86_400)'
mutate "serial epoch off by one"      'DateComponents(year: 1899, month: 12, day: 30)' 'DateComponents(year: 1899, month: 12, day: 31)'
mutate "formula text not neutralized" 'guard let first = value.first, "=+-@".contains(first) else { return value }' 'guard let first = value.first, "@".contains(first) else { return value }'
echo "survivors: $survivors"
[ "$survivors" -eq 0 ]
