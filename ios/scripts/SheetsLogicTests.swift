import Foundation

// Off-device tests for Health4AI/SheetsLogic.swift. Run: ios/scripts/test_sheets_logic.sh
// There is no Xcode test target yet, so this compiles the pure file plus these checks into
// a macOS executable. Every check must fail against a deliberately broken implementation
// (the script's --mutants mode proves it) or it is not guarding anything.

var failures = 0
func check(_ ok: Bool, _ name: String) {
    print(ok ? "PASS \(name)" : "FAIL \(name)")
    if !ok { failures += 1 }
}

var ny = Calendar(identifier: .gregorian)
ny.timeZone = TimeZone(identifier: "America/New_York")!

func at(_ s: String) -> Date {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: s)!
}
func hours(_ t: TimeInterval) -> Double { (t / 3600 * 100).rounded() / 100 }

// PKCE: RFC 7636 appendix B test vector.
check(PKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM",
      "pkce_rfc7636_vector")
let v = PKCE.makeVerifier()
check(v.count == 43 && !v.contains("=") && !v.contains("+") && !v.contains("/"), "pkce_verifier_shape")
check(PKCE.makeVerifier() != v, "pkce_verifier_random")

// Sleep window: noon to noon, owned by the wake-up date.
let w = SleepMath.window(for: at("2026-09-28T09:00:00-04:00"), calendar: ny)
check(w.start == at("2026-09-27T12:00:00-04:00") && w.end == at("2026-09-28T12:00:00-04:00"), "sleep_window_noon_to_noon")

// Two sources recording the same night overlap: count it once.
let watch = DateInterval(start: at("2026-09-27T23:00:00-04:00"), end: at("2026-09-28T06:00:00-04:00"))
let ring = DateInterval(start: at("2026-09-27T23:30:00-04:00"), end: at("2026-09-28T06:30:00-04:00"))
check(hours(SleepMath.unionDuration([watch, ring], clippedTo: w)) == 7.5, "sleep_overlap_counted_once")

// Disjoint segments add; contained segments do not.
let nap = DateInterval(start: at("2026-09-28T10:00:00-04:00"), end: at("2026-09-28T10:30:00-04:00"))
let inner = DateInterval(start: at("2026-09-28T01:00:00-04:00"), end: at("2026-09-28T02:00:00-04:00"))
check(hours(SleepMath.unionDuration([watch, nap, inner], clippedTo: w)) == 7.5, "sleep_disjoint_add_contained_not")

// Adjacent segments (stage boundaries) join without a gap or double count.
let a1 = DateInterval(start: at("2026-09-28T00:00:00-04:00"), end: at("2026-09-28T01:00:00-04:00"))
let a2 = DateInterval(start: at("2026-09-28T01:00:00-04:00"), end: at("2026-09-28T02:00:00-04:00"))
check(hours(SleepMath.unionDuration([a2, a1], clippedTo: w)) == 2.0, "sleep_adjacent_unsorted")

// Sleep that starts before the window only counts from noon.
let early = DateInterval(start: at("2026-09-27T10:00:00-04:00"), end: at("2026-09-27T13:00:00-04:00"))
check(hours(SleepMath.unionDuration([early], clippedTo: w)) == 1.0, "sleep_clipped_to_window")
check(SleepMath.unionDuration([], clippedTo: w) == 0, "sleep_empty")

// DST: 2026-11-01 is 25 hours long in New York; the fall-back night still gets one window.
let dst = SleepMath.window(for: at("2026-11-01T09:00:00-05:00"), calendar: ny)
check(hours(dst.duration) == 25.0, "sleep_window_dst_fall_back")

// Day keys and day stepping across DST.
check(DayKey.string(for: at("2026-09-28T23:30:00-04:00"), calendar: ny) == "2026-09-28", "daykey_local_late_evening")
let days = DayKey.days(from: at("2026-10-31T12:00:00-04:00"), through: at("2026-11-02T12:00:00-05:00"), calendar: ny)
check(days.map { DayKey.string(for: $0, calendar: ny) } == ["2026-10-31", "2026-11-01", "2026-11-02"], "days_across_dst")

// Upsert: existing dates update in place (row = index + 2), new dates append in order.
let plan = UpsertPlan.make(existingDates: ["2026-09-26", "2026-09-27"],
                           rows: [["2026-09-28", "3"], ["2026-09-27", "2"], ["2026-09-29", "4"]])
check(plan.updates.map(\.row) == [3] && plan.updates.first?.values == ["2026-09-27", "2"], "upsert_updates_existing_row")
check(plan.appends == [["2026-09-28", "3"], ["2026-09-29", "4"]], "upsert_appends_new_in_order")
let empty = UpsertPlan.make(existingDates: [], rows: [["2026-09-02", "b"], ["2026-09-01", "a"]])
check(empty.updates.isEmpty && empty.appends.map { $0[0] } == ["2026-09-01", "2026-09-02"], "upsert_empty_sheet_sorted")
let dup = UpsertPlan.make(existingDates: ["2026-09-27", "", "2026-09-27"], rows: [["2026-09-27", "x"]])
check(dup.updates.map(\.row) == [2], "upsert_first_duplicate_wins")

// Sheets date serials (read UNFORMATTED so a locale's "9/28/2026" never breaks matching).
check(DayKey.string(fromSheetsSerial: 46293) == "2026-09-28", "serial_to_daykey")
check(DayKey.string(fromSheetsSerial: 46293.75) == "2026-09-28", "serial_fraction_ignored")
check(DayKey.string(fromSheetsSerial: 0) == nil && DayKey.string(fromSheetsSerial: .nan) == nil, "serial_invalid")

// Formula injection: outside text never becomes a live formula.
check(SheetCell.text("=IMPORTXML(\"http://x\",\"//a\")") == "'=IMPORTXML(\"http://x\",\"//a\")", "text_neutralizes_equals")
check(SheetCell.text("+1") == "'+1" && SheetCell.text("-x") == "'-x" && SheetCell.text("@x") == "'@x", "text_neutralizes_plus_minus_at")
check(SheetCell.text("Apple Watch") == "Apple Watch" && SheetCell.text("") == "", "text_plain_unchanged")

// Cells: missing data is blank, never zero.
check(SheetCell.number(nil, decimals: 1) == "" && SheetCell.number(.nan, decimals: 1) == "", "cell_blank_for_missing")
check(SheetCell.number(7.456, decimals: 1) == "7.5" && SheetCell.number(0, decimals: 0) == "0", "cell_formats")

// First-connect sweep start: the oldest sample across types, and a failed query is an error.
struct ProbeError: Error {}
let today = at("2026-09-29T00:00:00-04:00")
let floor10 = at("2016-09-29T00:00:00-04:00")
let oldest = at("2014-05-01T08:00:00-04:00")
let recent = at("2026-08-22T08:00:00-04:00")
let resolved = try? SweepStart.resolve([.success(recent), .success(oldest), .success(nil)], today: today, floor: floor10, calendar: ny)
check(resolved == floor10, "sweep_start_floored_at_ten_years")
let mid = try? SweepStart.resolve([.success(recent), .success(at("2020-03-04T08:00:00-05:00"))], today: today, floor: floor10, calendar: ny)
check(mid == at("2020-03-04T00:00:00-05:00"), "sweep_start_is_oldest_type")
check((try? SweepStart.resolve([.success(nil), .success(nil)], today: today, floor: floor10, calendar: ny)) == today, "sweep_start_no_samples_is_today")
// Steps and heart rate fail, sleep answers with a later day: must throw, not start from sleep's day.
var threw = false
do { _ = try SweepStart.resolve([.failure(ProbeError()), .failure(ProbeError()), .success(recent)], today: today, floor: floor10, calendar: ny) }
catch { threw = true }
check(threw, "sweep_start_failed_type_throws")

// Grid: a new tab is 1000 rows; a decade of days must grow it before the write.
check(GridGrowth.rowsToAdd(currentRows: 1000, needed: 3652) == 2652, "grid_grows_for_decade")
check(GridGrowth.rowsToAdd(currentRows: 1000, needed: 42) == 0, "grid_no_growth_when_fits")
check(GridGrowth.rowsToAdd(currentRows: 1000, needed: 1001, headroom: 500) == 501 && GridGrowth.rowsToAdd(currentRows: 1000, needed: 1000, headroom: 500) == 0, "grid_headroom_only_when_growing")
let body = GridGrowth.appendRowsBody(sheetId: 7, count: 2652)
let req = (body["requests"] as? [[String: Any]])?.first?["appendDimension"] as? [String: Any]
check(req?["sheetId"] as? Int == 7 && req?["dimension"] as? String == "ROWS" && req?["length"] as? Int == 2652, "grid_append_dimension_body")

// History version: a sheet with rows from before the rebuild is rebuilt once.
check(HistoryVersion.needsRebuild(lastWrittenDay: "2026-09-30", historyVersion: nil), "rebuild_old_sheet")
check(!HistoryVersion.needsRebuild(lastWrittenDay: "2026-09-30", historyVersion: HistoryVersion.current), "rebuild_not_repeated")
check(HistoryVersion.needsRebuild(lastWrittenDay: "2026-10-02", historyVersion: 1), "rebuild_build57_sheet_once_more")
check(HistoryVersion.needsRebuild(lastWrittenDay: "2026-10-02", historyVersion: 2), "rebuild_build58_sheet_once_more")
check(AccessLimit.widened(previous: "2026-08-22", current: nil), "access_lifted_is_widened")
check(AccessLimit.widened(previous: "2026-08-22", current: "2026-01-01"), "access_earlier_is_widened")
check(!AccessLimit.widened(previous: "2026-08-22", current: "2026-08-22"), "access_same_not_widened")
check(!AccessLimit.widened(previous: "2026-08-22", current: "2026-09-01"), "access_later_not_widened")
check(!AccessLimit.widened(previous: nil, current: nil), "access_unknown_before_not_widened")
check(!AccessLimit.widened(previous: nil, current: "2026-08-22"), "access_first_seen_not_widened")
check(!HistoryVersion.needsRebuild(lastWrittenDay: nil, historyVersion: nil), "rebuild_not_needed_before_first_write")

// Workout names read as words, not HealthKit identifiers.
check(WorkoutName.display(fromIdentifier: "HKWorkoutActivityTypeUnderwaterDiving") == "Underwater Diving", "workout_name_words")
check(WorkoutName.display(fromIdentifier: "HKWorkoutActivityTypeOther") == "Other", "workout_name_single")
check(WorkoutName.display(fromIdentifier: "HKWorkoutActivityTypeHighIntensityIntervalTraining") == "High Intensity Interval Training", "workout_name_long")
check(WorkoutName.display(fromIdentifier: "HKWorkoutActivityTypeTableTennis") == "Table Tennis", "workout_name_two")

await runSyncTests(check, calendar: ny, at: at)

// Column A of the Daily tab: only real yyyy-MM-dd keys count, and only from 2000 on.
check(DateKeys.isKey("2026-09-30") && !DateKeys.isKey("1/5/2020") && !DateKeys.isKey("2019") && !DateKeys.isKey("2026-13-01") && !DateKeys.isKey("my notes"), "datekey_shape")
check(DateKeys.earliestHeld(["2019", "1/5/2020", "1900-01-04", "2026-08-22", "2026-08-21"]) == "2026-08-21", "datekey_earliest_ignores_stray")
check(DateKeys.earliestHeld(["1/5/2020", "note"]) == nil, "datekey_earliest_none_when_only_stray")
check(DateKeys.staleRuns(["2026-01-01", "2026-01-02", "2026-01-03", "my notes", "2026-01-05"], keptRows: 3) == [4...4, 6...6], "datekey_stale_runs_skip_text")
check(DateKeys.staleRuns(["2026-01-01", "2026-01-02"], keptRows: 3).isEmpty, "datekey_stale_none_inside_table")
let t0 = at("2026-09-30T12:00:00-04:00")
check(RebuildBackoff.isBlocked(notBefore: t0.addingTimeInterval(60), now: t0) && !RebuildBackoff.isBlocked(notBefore: nil, now: t0) && !RebuildBackoff.isBlocked(notBefore: t0, now: t0), "backoff_window")

print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
