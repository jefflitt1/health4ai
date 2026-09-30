import Foundation

// Drives SheetsSyncCore (Health4AI/SheetsSync.swift) with a fake sheet and a fake HealthKit
// source, so the ORDER of reads, builds, writes and clears is tested: a failure injected at
// each step must leave the sheet intact. Called from SheetsLogicTests.swift.

struct Injected: Error {}

final class FakeSheet: SheetsAPI {
    var daily: [[String]] = []          // Daily rows from row 2
    var workouts: [[String]] = []       // Workouts rows from row 2
    var grid = [SheetTabs.daily: 1000, SheetTabs.workouts: 1000]
    var about: [[String]] = []
    var ops: [String] = []
    var failOp: String?                 // throws Injected when this op is reached
    var growRequests = 0      // actual appendDimension requests (the grid changed)

    private func hit(_ op: String) throws { ops.append(op); if failOp == op { throw Injected() } }

    // "Daily!A2:P40" / "Daily!A2:P" / "Daily!A2:A" -> (tab, firstRow, lastRow?)
    private func parse(_ r: String) -> (tab: String, first: Int, last: Int?) {
        let parts = r.split(separator: "!"); let cells = parts[1].split(separator: ":")
        func row(_ c: Substring) -> Int? { Int(c.drop { $0.isLetter }) }
        return (String(parts[0]), row(cells[0]) ?? 1, cells.count > 1 ? row(cells[1]) : nil)
    }

    func readDateColumn(spreadsheetId: String, range: String) async throws -> [String] {
        try hit("readDates"); return daily.map { $0.first ?? "" }
    }
    func readColumn(spreadsheetId: String, range: String) async throws -> [String] {
        try hit("readWorkoutIds"); return workouts.map { $0[7] }
    }
    func writeRanges(spreadsheetId: String, _ ranges: [(range: String, rows: [[String]])]) async throws {
        try hit("write")
        // Atomic like values:batchUpdate: validate every range first, apply none on error.
        for r in ranges {
            let p = parse(r.range)
            if let g = grid[p.tab], p.first + r.rows.count - 1 > g { throw SheetsError.http(status: 400, detail: "exceeds grid limits") }
        }
        for r in ranges {
            let p = parse(r.range)
            switch p.tab {
            case SheetTabs.daily: place(&daily, r.rows, at: p.first - 2)
            case SheetTabs.workouts: place(&workouts, r.rows, at: p.first - 2)
            default: about = r.rows
            }
        }
    }
    private func place(_ col: inout [[String]], _ rows: [[String]], at i: Int) {
        while col.count < i + rows.count { col.append([]) }
        for (k, row) in rows.enumerated() { col[i + k] = row }
    }
    func append(spreadsheetId: String, range: String, rows: [[String]]) async throws {
        try hit("append"); workouts += rows
    }
    func clear(spreadsheetId: String, ranges: [String]) async throws {
        try hit("clear")
        for r in ranges {
            let p = parse(r)
            func wipe(_ col: inout [[String]]) {
                let from = p.first - 2, to = min((p.last ?? Int.max) - 2, col.count - 1)
                if from <= to { for i in from...to { col[i] = [] } }
                while let l = col.last, l.isEmpty { col.removeLast() }
            }
            if p.tab == SheetTabs.daily { wipe(&daily) } else { wipe(&workouts) }
        }
    }
    func ensureRows(spreadsheetId: String, tab: String, needed: Int, headroom: Int) async throws -> Int {
        try hit("ensureRows")
        let add = GridGrowth.rowsToAdd(currentRows: grid[tab]!, needed: needed, headroom: headroom)
        if add > 0 { growRequests += 1 }
        grid[tab]! += add
        return grid[tab]!
    }
}

struct FakeSource: SheetsHistorySource {
    var earliest: Date
    var calendar: Calendar
    var failDailyFrom: Date?            // a HealthKit error (locked device) from this chunk on
    var failEarliest = false
    var workoutDays: [Date] = []

    func earliestDataDay(now: Date) async throws -> Date {
        if failEarliest { throw Injected() }
        return earliest
    }
    func dailyRows(from: Date, through: Date) async throws -> [[String]] {
        if let f = failDailyFrom, from >= f { throw Injected() }
        return DayKey.days(from: from, through: through, calendar: calendar).map {
            [DayKey.string(for: $0, calendar: calendar), "100"] + Array(repeating: "", count: 14)
        }
    }
    func workoutRows(from: Date, to: Date) async throws -> [[String]] {
        workoutDays.filter { $0 >= from && $0 < to }.map {
            [DayKey.string(for: $0, calendar: calendar), "07:00", "Running", "30", "", "", "Watch", "id-\(DayKey.string(for: $0, calendar: calendar))"]
        }
    }
}

func runSyncTests(_ check: (Bool, String) -> Void, calendar cal: Calendar, at: (String) -> Date) async {
    let now = at("2026-09-30T12:00:00-04:00")
    let today = cal.startOfDay(for: now)
    func day(_ k: String) -> Date { cal.startOfDay(for: at("\(k)T12:00:00-04:00")) }
    let oldStart = day("2026-08-22")
    let oldRows = DayKey.days(from: oldStart, through: today, calendar: cal).map {
        [DayKey.string(for: $0, calendar: cal), "100"] + Array(repeating: "", count: 14)
    }
    func oldSheet() -> FakeSheet {
        let s = FakeSheet(); s.daily = oldRows
        s.workouts = [["2026-08-30", "07:00", "HKWorkoutActivityTypeOther", "30", "", "", "Watch", "id-old"]]
        return s
    }
    func source(_ configure: (inout FakeSource) -> Void = { _ in }) -> FakeSource {
        var src = FakeSource(earliest: day("2016-09-30"), calendar: cal, workoutDays: [day("2020-01-05"), day("2026-08-30")])
        configure(&src); return src
    }
    let oldProgress = SheetsProgress(lastWrittenDay: "2026-09-30", historyVersion: nil)
    var saved: [SheetsProgress] = []

    func drive(_ sheet: FakeSheet, _ src: FakeSource, allowRebuild: Bool = true,
               progress: SheetsProgress = oldProgress) async -> (progress: SheetsProgress, error: Error?) {
        var p = progress; saved = []
        var core = SheetsSyncCore(api: sheet, source: src, calendar: cal)
        core.rebuildExtras = [("About!A1:B1", [["Column", "Meaning"]])]
        do {
            _ = try await core.run(spreadsheetId: "s", progress: &p, allowRebuild: allowRebuild, now: now) { saved.append($0) }
            return (p, nil)
        } catch { return (p, error) }
    }

    // Rebuild from a late-starting sheet: full history, ascending, old rows replaced.
    let ok = oldSheet()
    let r1 = await drive(ok, source())
    check(r1.error == nil && ok.daily.count == 3653 && ok.daily.first?.first == "2016-09-30" && ok.daily.last?.first == "2026-09-30", "rebuild_full_history_to_today")
    check(ok.daily.map { $0[0] } == ok.daily.map { $0[0] }.sorted() && Set(ok.daily.map { $0[0] }).count == ok.daily.count, "rebuild_date_order_no_duplicates")
    check(ok.workouts.map { $0[0] } == ["2020-01-05", "2026-08-30"] && ok.workouts.allSatisfy { $0[2] == "Running" }, "rebuild_replaces_workouts")
    check(r1.progress.historyVersion == HistoryVersion.current && r1.progress.lastWrittenDay == "2026-09-30" && saved.count == 1, "rebuild_saves_progress_once")
    check(ok.grid[SheetTabs.daily]! >= 3653 && ok.growRequests == 1, "rebuild_grows_grid_with_one_request")
    check(ok.about == [["Column", "Meaning"]], "rebuild_rewrites_about_in_same_write")

    // A HealthKit error (locked device) part-way through the rebuild: the sheet is untouched.
    let locked = oldSheet()
    let r2 = await drive(locked, source { $0.failDailyFrom = day("2019-01-01") })
    check(r2.error != nil && locked.daily == oldRows && locked.workouts.count == 1 && !locked.ops.contains("clear") && !locked.ops.contains("write"), "rebuild_healthkit_error_leaves_sheet_intact")
    check(r2.progress == oldProgress && saved.isEmpty, "rebuild_failure_keeps_old_progress")

    // Network failure on the one write: nothing changed, rebuild retried next pass.
    let down = oldSheet(); down.failOp = "write"
    let r3 = await drive(down, source())
    check(r3.error != nil && down.daily == oldRows && r3.progress == oldProgress, "rebuild_write_failure_leaves_sheet_intact")

    // Health access off for steps/HR/sleep: the probes answer with a LATER day. No rebuild.
    let late = oldSheet()
    let r4 = await drive(late, source { $0.earliest = day("2026-08-30") })
    check(late.daily.first?.first == "2026-08-22" && late.daily.count >= oldRows.count && !late.ops.contains("clear"), "late_start_does_not_destroy_rows")
    check((r4.error as? SheetsError).map { if case .noHealthData = $0 { return true } else { return false } } ?? false, "late_start_surfaces_health_access")
    check(r4.progress.historyVersion == nil, "late_start_keeps_old_version")

    // Earliest-day query failure aborts before anything is read or written.
    let noProbe = oldSheet()
    let r5 = await drive(noProbe, source { $0.failEarliest = true })
    check(r5.error != nil && noProbe.daily == oldRows && !noProbe.ops.contains("write"), "earliest_failure_fails_pass_untouched")

    // Background pass: incremental only, even though the sheet is due a rebuild.
    let bg = oldSheet()
    let r6 = await drive(bg, source(), allowRebuild: false)
    check(r6.error == nil && bg.daily.first?.first == "2026-08-22" && bg.daily.count == oldRows.count && !bg.ops.contains("clear"), "background_pass_is_incremental_only")
    check(r6.progress.historyVersion == nil, "background_pass_keeps_rebuild_pending")

    // Fresh connect: sweeps 10 years with ONE growth request up front, workouts first.
    let fresh = FakeSheet()
    let r7 = await drive(fresh, source(), progress: SheetsProgress(lastWrittenDay: nil, historyVersion: nil))
    check(r7.error == nil && fresh.daily.count == 3653 && fresh.daily.first?.first == "2016-09-30", "fresh_sweep_writes_ten_years")
    check(fresh.growRequests == 1 && r7.progress.historyVersion == HistoryVersion.current, "fresh_sweep_grows_once_and_marks_version")
    check(fresh.workouts.count == 2, "fresh_sweep_writes_workouts")
    let nextDay = at("2026-10-01T12:00:00-04:00")
    var again = r7.progress
    var core = SheetsSyncCore(api: fresh, source: source(), calendar: cal)
    core.rebuildExtras = []
    _ = try? await core.run(spreadsheetId: "s", progress: &again, allowRebuild: true, now: nextDay) { _ in }
    check(fresh.daily.count == 3654 && fresh.daily.last?.first == "2026-10-01" && fresh.growRequests == 1, "incremental_after_sweep_appends_without_growth_request")
}
