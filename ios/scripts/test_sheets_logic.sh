#!/usr/bin/env bash
# Off-device tests for the Google Sheets destination's pure logic (Health4AI/SheetsLogic.swift).
# Usage: ios/scripts/test_sheets_logic.sh            # run the checks
#        ios/scripts/test_sheets_logic.sh --mutants  # prove each guarded behaviour fails when broken
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../Health4AI/SheetsLogic.swift"
SYNC="$HERE/../Health4AI/SheetsSync.swift"
SLEEP="$HERE/../Health4AI/SheetsSync+SleepStages.swift"
SYNCTESTS="$HERE/SheetsSyncTests.swift"
TESTS="$HERE/SheetsLogicTests.swift"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

run() { # $1 = logic, $2 = sync, $3 = sleep stages file. Exit 2 = did not build (never a killed mutant).
  # Top-level test code is only legal in a file named main.swift.
  cp "$TESTS" "$WORK/main.swift"
  cp "$1" "$WORK/SheetsLogic.swift"; cp "$2" "$WORK/SheetsSync.swift"; cp "$3" "$WORK/SheetsSleep.swift"
  cp "$SYNCTESTS" "$WORK/SheetsSyncTests.swift"
  xcrun swiftc -O -D H4A_SHEETS -o "$WORK/t" "$WORK/SheetsLogic.swift" "$WORK/SheetsSync.swift" "$WORK/SheetsSleep.swift" \
    "$WORK/SheetsSyncTests.swift" "$WORK/main.swift" 2>"$WORK/build.log" || { cat "$WORK/build.log"; return 2; }
  "$WORK/t"
}

if [ "${1:-}" != "--mutants" ]; then
  run "$SRC" "$SYNC" "$SLEEP"
  exit $?
fi

# Each mutant breaks one behaviour; the suite must FAIL on every one.
mutate() { # name, old, new, [sync|sleep] - mutates SheetsLogic.swift unless a 4th arg names another file
  local name="$1" old="$2" new="$3" target="$SRC"
  [ "${4:-}" = sync ] && target="$SYNC"
  [ "${4:-}" = sleep ] && target="$SLEEP"
  python3 - "$target" "$WORK/m.swift" "$old" "$new" <<'EOF'
import sys
src, out, old, new = sys.argv[1:]
s = open(src).read()
assert s.count(old) == 1, f"mutant anchor not unique: {old!r}"
open(out, "w").write(s.replace(old, new))
EOF
  local rc=0
  case "${4:-}" in
    sync)  run "$SRC" "$WORK/m.swift" "$SLEEP" >/dev/null 2>&1 || rc=$? ;;
    sleep) run "$SRC" "$SYNC" "$WORK/m.swift" >/dev/null 2>&1 || rc=$? ;;
    *)     run "$WORK/m.swift" "$SYNC" "$SLEEP" >/dev/null 2>&1 || rc=$? ;;
  esac
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
mutate "sweep start swallows query errors" 'if let date = try result.get(), date < earliest' 'if let date = (try? result.get()) ?? nil, date < earliest'
mutate "grid never grows"             'currentRows >= needed ? 0 : needed + headroom - currentRows' '0'
mutate "workout name left raw"        'return out.isEmpty ? id : out' 'return id'
mutate "old sheet never rebuilt"      'lastWrittenDay != nil && (historyVersion ?? 0) < current' 'false'
mutate "rebuild repeats forever"      '(historyVersion ?? 0) < current' '(historyVersion ?? 0) <= current'
mutate "rebuild ignores a late start"  'if let firstHeld = DateKeys.earliestHeld(existing), DayKey' 'if false, let firstHeld = DateKeys.earliestHeld(existing), DayKey' sync
mutate "rebuild runs in background"    'if allowRebuild, !RebuildBackoff' 'if !RebuildBackoff' sync
mutate "refused rebuild not reported"  'result.rebuildSkipped = rebuildRefused' '' sync
mutate "rebuild never marks version"   'progress.historyVersion = HistoryVersion.current
                    progress.rebuildNotBefore = nil' 'progress.rebuildNotBefore = nil' sync
mutate "no up-front grid growth"       'needed: existing.count + 1 + days, headroom: Self.gridHeadroom)' 'needed: 1, headroom: 0)' sync
mutate "rebuild drops stale tail"      'if !stale.isEmpty {' 'if false {' sync
mutate "rebuild skips about rewrite"   'if !rebuildExtras.isEmpty { try await api.writeRanges' 'if false { try await api.writeRanges' sync
mutate "workouts not merged"           'let added = mergeRecentWorkouts ? try await addWorkouts(id: id, from: start, today: today) : 0' 'let added = 0' sync
mutate "raw workout names left"        'try await tidyWorkoutNames(id: id)
        var out = SheetsPassResult' 'var out = SheetsPassResult' sync
mutate "failed rebuild not backed off" 'progress.rebuildNotBefore = now.addingTimeInterval(RebuildBackoff.interval)
                progress.rebuildFailed = true
                persist(progress)
                throw error' 'progress.rebuildFailed = true
                throw error' sync
mutate "backoff ignored"               'allowRebuild, !RebuildBackoff.isBlocked(notBefore: progress.rebuildNotBefore, now: now),' 'allowRebuild,' sync
mutate "daily written in one request"  'static let writeChunkRows = 800' 'static let writeChunkRows = 100000' sync
mutate "stale clear wipes any text"    'guard row > keptRows, isKey(raw.trimmingCharacters(in: .whitespaces)) else { continue }' 'guard row > keptRows else { continue }'
mutate "stray keys steer the guard"    'minYear: Int = 2000' 'minYear: Int = 0'
mutate "cancel treated as failure"     'throw CancellationError()   // iOS took' 'throw Injected()   // iOS took' sync
mutate "empty first chunk fails the sweep" 'guard chunkEnd < today else {
                    throw SheetsError.noHealthData(checked: Self.checkedRange(start, today, calendar: calendar))
                }' 'throw SheetsError.noHealthData(checked: "")' sync
mutate "empty history reported as synced" 'guard chunkEnd < today else {
                    throw SheetsError.noHealthData(checked: Self.checkedRange(start, today, calendar: calendar))
                }
                chunkStart' 'chunkStart' sync
mutate "sleep night midnight-based"    'value: 12, to: start)!, calendar: calendar)' 'value: 0, to: start)!, calendar: calendar)'
mutate "sleep stage names swapped"     'case 4: return "Deep"' 'case 4: return "REM"'
mutate "sleep tail reads typed text"   'if DateKeys.isKey(night), night >= key { return i + 2 }' 'if night >= key { return i + 2 }'
mutate "sleep stages on by default"    'var saveSleepStages = false' 'var saveSleepStages = true' sync
mutate "sleep records not deduped"     '.filter { !known.contains($0[SleepStageLayout.idIndex]) }' '.filter { _ in true }' sleep
mutate "sleep overlap only two nights" 'static let sleepOverlapDays = 7' 'static let sleepOverlapDays = 2' sleep
mutate "sleep progress never advances" 'progress.sleepStagesThrough = DayKey.string(for: chunkEnd, calendar: calendar)' '' sleep
mutate "deleted sleep tab not refilled" 'if try await api.ensureTab(spreadsheetId: id, title: tab) { progress.sleepStagesThrough = nil }' '_ = try await api.ensureTab(spreadsheetId: id, title: tab)' sleep
mutate "sleep header not written"      'try await api.writeRanges(spreadsheetId: id, header)' '' sleep
mutate "header only on a new tab"      'if progress.sleepStagesThrough == nil {
            // Written' 'if false {
            // Written' sleep
mutate "late choice ignored"           'let latest = latestChoices?() ?? SaveChoiceFlags' 'let latest = Optional<SaveChoiceFlags>.none ?? SaveChoiceFlags' sync
mutate "catch-up never reported done"  'result.workoutsCaughtUp = true' '' sync
mutate "sleep appended in one request" 'static let appendChunkRows = 2000' 'static let appendChunkRows = 1000000' sleep
mutate "empty sleep marked done"       'guard let oldest = try await source.oldestSleepRecord() else { return 0 }' 'guard let oldest = try await source.oldestSleepRecord() else { progress.sleepStagesThrough = DayKey.string(for: today, calendar: calendar); return 0 }' sleep
mutate "workouts off ignored"          'private var mergeRecentWorkouts: Bool { saveWorkouts && !workoutsCatchUp }' 'private var mergeRecentWorkouts: Bool { !workoutsCatchUp }' sync
mutate "workouts catch-up ignored"     'if latest.workouts && latest.workoutsCatchUp {' 'if false {' sync
mutate "workouts appended in one request" 'try await appendInPieces(id: id, range: "\(SheetTabs.workouts)!A:H", rows: fresh)' 'try await api.append(spreadsheetId: id, range: "\(SheetTabs.workouts)!A:H", rows: fresh)' sync
mutate "range refusal not split"       '} catch let error where splittable(error) {' '} catch let error where false && splittable(error) {'
mutate "split stops at whole range"    'guard days.count > 1 else { out.failedDays.append(days[0]); return }' 'out.failedDays += days; return'
mutate "single refused day thrown"     'guard days.count > 1 else { out.failedDays.append(days[0]); return }' 'guard days.count > 1 else { throw error }'
mutate "unread not saved per chunk"    'progress.unreadDays = Set(progress.unreadDays).union(chunk.unread.values.joined()).sorted()' '' sync
mutate "split swallows other errors"   'out.parts.append((days, try await query(days)))' 'if let v = try? await query(days) { out.parts.append((days, v)) } else { out.failedDays += days }'
mutate "unread cells not reported"     'result.daysWritten += rows.count
            result.addUnread(chunk.unread)' 'result.daysWritten += rows.count' sync
mutate "retry result ignored"          'let chunk = try await source.dailyRows(from: day, through: day)
            result.addUnread(chunk.unread)' 'let chunk = try await source.dailyRows(from: day, through: day)' sync
mutate "rebuild unread not reported"   'unread.addUnread(chunk.unread)' '' sync
mutate "unread days never retried"     'try await retryUnread(id: id, before: start, existing: existing, progress: &progress, result: &result)' '' sync
mutate "retried rows not written"      'if !ranges.isEmpty { try await api.writeRanges(spreadsheetId: id, ranges) }' '' sync
mutate "unreached retries dropped"     '.union(earlier.dropFirst(tried.count))' '' sync
mutate "retries unbounded"             'static let unreadRetriesPerPass = 30' 'static let unreadRetriesPerPass = 100000' sync
mutate "refused-only chunk skipped"    'if pendingFirstWrite, !Self.hasData(rows), chunk.unread.isEmpty {' 'if pendingFirstWrite, !Self.hasData(rows) {' sync
mutate "refused cells blank good data" 'guard !refused.isEmpty else { return [(' 'guard false else { return [(' sync
mutate "rebuild blanks held values"    'try await keepHeldValues(id: id, refused: refused, in: &daily)' '' sync
mutate "rebuild holds by position"     'for (i, key) in existing.enumerated() where i < values.count && !values[i].isEmpty { byDay[key] = values[i] }' 'for (i, key) in daily.map({ $0[0] }).enumerated() where i < values.count && !values[i].isEmpty { byDay[key] = values[i] }' sync
mutate "rebuild fills unheld refused"  'if let value = held[col]?[daily[i][0]] { daily[i][col] = value }' 'daily[i][col] = held[col]?[daily[i][0]] ?? "100"' sync
mutate "rewrite ignores refused cols"  'refused: chunk.refusedColumns(on: $0.values[0]))
            }
            if !plan.appends.isEmpty' 'refused: [])
            }
            if !plan.appends.isEmpty' sync
echo "survivors: $survivors"
[ "$survivors" -eq 0 ]
