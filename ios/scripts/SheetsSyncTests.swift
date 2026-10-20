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
    var sleep: [[String]] = []          // Sleep stages rows from row 2
    var sleepHeader: [String] = []
    var tabs: Set<String> = [SheetTabs.daily, SheetTabs.workouts, SheetTabs.about]
    var sleepAppendSizes: [Int] = []
    var workoutAppendSizes: [Int] = []
    var failSleepAppendNumber: Int?     // the Nth append to Sleep stages throws
    var ops: [String] = []
    var failOp: String?                 // throws Injected when this op is reached
    var writes = 0
    var maxRowsPerWrite = 0
    var failWriteNumber: Int?           // the Nth writeRanges call throws
    var afterFirstRead: (() -> Void)?   // a person edits the sheet between our reads
    var reads = 0
    var growRequests = 0      // actual appendDimension requests (the grid changed)

    private func hit(_ op: String) throws { ops.append(op); if failOp == op { throw Injected() } }

    // "Daily!A2:P40" / "Daily!A2:P" / "Daily!A2:A" -> (tab, firstRow, lastRow?)
    private func parse(_ r: String) -> (tab: String, first: Int, last: Int?, col: Character) {
        let parts = r.split(separator: "!"); let cells = parts[1].split(separator: ":")
        func row(_ c: Substring) -> Int? { Int(c.drop { $0.isLetter }) }
        let tab = String(parts[0]).trimmingCharacters(in: CharacterSet(charactersIn: "'"))
        return (tab, row(cells[0]) ?? 1, cells.count > 1 ? row(cells[1]) : nil, cells[0].first!)
    }

    func readDateColumn(spreadsheetId: String, range: String) async throws -> [String] {
        if parse(range).tab == SheetTabs.sleepStages { try hit("readNights"); return sleep.map { $0.first ?? "" } }
        try hit("readDates"); reads += 1
        let snapshot = daily.map { $0.first ?? "" }
        if reads == 1 { afterFirstRead?() }
        return snapshot
    }
    func readColumn(spreadsheetId: String, range: String) async throws -> [String] {
        let p = parse(range)
        if p.tab == SheetTabs.sleepStages {
            try hit("readSleepIds")
            return sleep.dropFirst(p.first - 2).map { $0.count > 6 ? $0[6] : "" }
        }
        if p.tab == SheetTabs.daily {
            try hit("readDailyColumn")
            let c = Int(p.col.asciiValue! - 65)
            return daily.dropFirst(p.first - 2).map { $0.count > c ? $0[c] : "" }
        }
        try hit("readWorkoutIds")
        if range.contains("C2") { return workouts.map { $0.count > 2 ? $0[2] : "" } }
        return workouts.map { $0[7] }
    }
    func writeRanges(spreadsheetId: String, _ ranges: [(range: String, rows: [[String]])]) async throws {
        try hit("write"); writes += 1
        if failWriteNumber == writes { throw Injected() }
        maxRowsPerWrite = max(maxRowsPerWrite, ranges.map { $0.rows.count }.max() ?? 0)
        // Google does not document multi-range all-or-nothing, so this applies ranges in order
        // and stops at the first bad one, leaving the earlier ones written.
        for r in ranges {
            let p = parse(r.range)
            if let g = grid[p.tab], p.first + r.rows.count - 1 > g { throw SheetsError.http(status: 400, detail: "exceeds grid limits") }
            switch p.tab {
            case SheetTabs.daily where p.col != "A" || !r.range.contains(":P"):   // a partial row: only those columns change
                let offset = Int(p.col.asciiValue! - 65), i = p.first - 2
                var existing = daily[i]; while existing.count < offset + r.rows[0].count { existing.append("") }
                existing.replaceSubrange(offset..<offset + r.rows[0].count, with: r.rows[0]); daily[i] = existing
            case SheetTabs.daily: place(&daily, r.rows, at: p.first - 2)
            case SheetTabs.workouts: place(&workouts, r.rows, at: p.first - 2, col: p.col)
            case SheetTabs.sleepStages: if p.first == 1 { sleepHeader = r.rows[0] } else { place(&sleep, r.rows, at: p.first - 2) }
            default: about = r.rows
            }
        }
    }
    private func place(_ col: inout [[String]], _ rows: [[String]], at i: Int, col letter: Character = "A") {
        while col.count < i + rows.count { col.append([]) }
        for (k, row) in rows.enumerated() {
            if letter == "C" {      // a single-cell write into the Type column
                var existing = col[i + k]; while existing.count < 3 { existing.append("") }
                existing[2] = row[0]; col[i + k] = existing
            } else { col[i + k] = row }
        }
    }
    func append(spreadsheetId: String, range: String, rows: [[String]]) async throws {
        if parse(range).tab == SheetTabs.sleepStages {
            try hit("appendSleep"); sleepAppendSizes.append(rows.count)
            if failSleepAppendNumber == sleepAppendSizes.count { throw Injected() }
            sleep += rows; return
        }
        try hit("append"); workoutAppendSizes.append(rows.count); workouts += rows
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
    func ensureTab(spreadsheetId: String, title: String) async throws -> Bool {
        try hit("ensureTab")
        return tabs.insert(title).inserted
    }
    func ensureRows(spreadsheetId: String, tab: String, needed: Int, headroom: Int) async throws -> Int {
        try hit("ensureRows")
        let add = GridGrowth.rowsToAdd(currentRows: grid[tab]!, needed: needed, headroom: headroom)
        if add > 0 { growRequests += 1 }
        grid[tab]! += add
        return grid[tab]!
    }
}

final class Counter { var n = 0 }

struct FakeSource: SheetsHistorySource {
    var earliest: Date
    var calendar: Calendar
    var failDailyFrom: Date?            // a HealthKit error (locked device) from this chunk on
    var failEarliest = false
    var cancelDailyFrom: Date?
    var earliestCalls: Int { counter.n }
    let counter = Counter()
    var workoutDays: [Date] = []
    var emptyBefore: Date?              // days before this come back blank (a gap after the sweep start)
    var sleepNights: [Date] = []        // nights (wake-up dates) with sleep recorded
    var recordsPerNight = 3
    var lateRecords: [Date] = []        // nights that gained one more record after a sync
    var unreadStepDays: [Date] = []     // days HealthKit refused to read steps for (RangeSplit)
    var duringDailyRead: (() -> Void)?  // the person edits the sheet while HealthKit is read

    func earliestDataDay(now: Date) async throws -> Date {
        counter.n += 1
        if failEarliest { throw Injected() }
        return earliest
    }
    func dailyRows(from: Date, through: Date) async throws -> DailyChunk {
        duringDailyRead?()
        if let f = failDailyFrom, from >= f { throw Injected() }
        if let c = cancelDailyFrom, from >= c { throw CancellationError() }
        let days = DayKey.days(from: from, through: through, calendar: calendar)
        let rows = days.map { day in
            [DayKey.string(for: day, calendar: calendar),
             emptyBefore.map { $0 > day } == true || unreadStepDays.contains(day) ? "" : "100"] + Array(repeating: "", count: 14)
        }
        let unread = days.filter { unreadStepDays.contains($0) }.map { DayKey.string(for: $0, calendar: calendar) }
        return DailyChunk(rows: rows, unread: unread.isEmpty ? [:] : ["Steps": unread])
    }
    func oldestSleepRecord() async throws -> Date? {
        sleepNights.min().map { calendar.date(byAdding: .hour, value: -2, to: $0)! }   // 22:00 the evening before
    }
    func sleepStageRows(nights from: Date, through: Date) async throws -> [[String]] {
        func rows(_ night: Date, _ ids: Range<Int>) -> [[String]] {
            let key = DayKey.string(for: night, calendar: calendar)
            return ids.map { [key, "Core", "\(key) 01:00", "\(key) 02:00", "60.0", "Watch", "sl-\(key)-\($0)"] }
        }
        return sleepNights.filter { $0 >= from && $0 <= through }.flatMap { night in
            rows(night, 0..<recordsPerNight) + (lateRecords.contains(night) ? rows(night, 100..<101) : [])
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

    var lastResult: SheetsPassResult?
    func drive(_ sheet: FakeSheet, _ src: FakeSource, allowRebuild: Bool = true,
               progress: SheetsProgress = oldProgress, at passNow: Date? = nil) async -> (progress: SheetsProgress, error: Error?) {
        var p = progress; saved = []; lastResult = nil
        var core = SheetsSyncCore(api: sheet, source: src, calendar: cal)
        core.rebuildExtras = [("About!A1:B1", [["Column", "Meaning"]])]
        do {
            lastResult = try await core.run(spreadsheetId: "s", progress: &p, allowRebuild: allowRebuild, now: passNow ?? now) { saved.append($0) }
            return (p, nil)
        } catch { return (p, error) }
    }

    // Rebuild from a late-starting sheet: full history, ascending, old rows replaced.
    let ok = oldSheet()
    let r1 = await drive(ok, source())
    check(r1.error == nil && ok.daily.count == 3653 && ok.daily.first?.first == "2016-09-30" && ok.daily.last?.first == "2026-09-30", "rebuild_full_history_to_today")
    check(ok.daily.map { $0[0] } == ok.daily.map { $0[0] }.sorted() && Set(ok.daily.map { $0[0] }).count == ok.daily.count, "rebuild_date_order_no_duplicates")
    check(ok.workouts.count == 3 && ok.workouts[0][7] == "id-old" && ok.workouts.allSatisfy { !$0[2].hasPrefix("HK") }
          && ok.workouts[0][2] == "Other", "rebuild_merges_workouts_and_tidies_names")
    check(ok.daily.count > 800 && ok.maxRowsPerWrite <= SheetsSyncCore.writeChunkRows && ok.writes >= 5, "rebuild_writes_in_chunks")
    check(r1.progress.historyVersion == HistoryVersion.current && r1.progress.lastWrittenDay == "2026-09-30" && saved.count == 1, "rebuild_saves_progress_once")
    check(ok.grid[SheetTabs.daily]! >= 3653 && ok.growRequests == 1, "rebuild_grows_grid_with_one_request")
    check(ok.about == [["Column", "Meaning"]], "rebuild_rewrites_about_in_same_write")

    // An old tab LONGER than the rebuilt one (duplicate days): the stale tail is cleared.
    let longer = oldSheet()
    longer.daily = oldRows + Array(repeating: oldRows[0], count: 5000)
    let r8 = await drive(longer, source { $0.earliest = day("2026-08-01") })
    check(r8.error == nil && longer.daily.count == 61 && longer.daily.first?.first == "2026-08-01", "rebuild_clears_stale_tail")

    // A HealthKit error (locked device) part-way through the rebuild: the sheet is untouched.
    let locked = oldSheet()
    let r2 = await drive(locked, source { $0.failDailyFrom = day("2019-01-01") })
    check(r2.error != nil && locked.daily == oldRows && locked.workouts.count == 1 && !locked.ops.contains("clear") && !locked.ops.contains("write"), "rebuild_healthkit_error_leaves_sheet_intact")
    check(r2.progress.lastWrittenDay == "2026-09-30" && r2.progress.historyVersion == nil, "rebuild_failure_keeps_old_progress")
    check(r2.progress.rebuildFailed, "rebuild_failure_flagged")

    // Network failure on the one write: nothing changed, rebuild retried next pass.
    let down = oldSheet(); down.failOp = "write"
    let r3 = await drive(down, source())
    check(r3.error != nil && down.daily == oldRows && r3.progress.historyVersion == nil && r3.progress.lastWrittenDay == "2026-09-30", "rebuild_write_failure_leaves_sheet_intact")

    // Health access off for steps/HR/sleep: the probes answer with a LATER day. No rebuild, but
    // the incremental work succeeds (no error, no attention state) and is reported as skipped.
    let late = oldSheet()
    let r4 = await drive(late, source { $0.earliest = day("2026-08-30") })
    check(late.daily.first?.first == "2026-08-22" && late.daily.count >= oldRows.count && !late.ops.contains("clear"), "late_start_does_not_destroy_rows")
    check(r4.error == nil && lastResult?.rebuildSkipped == true, "late_start_is_skipped_not_failed")
    check(r4.progress.historyVersion == nil && r4.progress.rebuildNotBefore != nil, "late_start_keeps_old_version_and_backs_off")
    check(!r4.progress.rebuildFailed, "refused_rebuild_not_flagged_failed")

    // Workouts unreadable (denied): existing workout history must survive a rebuild.
    let denied = oldSheet()
    denied.workouts = [["2019-05-01", "07:00", "Running", "30", "", "", "Watch", "id-a"], ["2026-08-30", "07:00", "Cycling", "30", "", "", "Watch", "id-b"]]
    let r9 = await drive(denied, source { $0.workoutDays = [] })
    check(r9.error == nil && denied.workouts.count == 2 && r9.progress.historyVersion == HistoryVersion.current, "workouts_denied_keeps_history")

    // Stray text, a bare year and a number in column A must neither block nor steer the guard.
    let stray = oldSheet()
    stray.daily = [["2019"], ["1/5/2020"], ["1900-01-04"]] + oldRows
    let r10 = await drive(stray, source { $0.earliest = day("2026-08-22") })
    check(r10.error == nil && lastResult?.rebuildSkipped == false && r10.progress.historyVersion == HistoryVersion.current, "stray_column_a_does_not_block_rebuild")

    // A failing rebuild backs off: the next foreground pass (inside the window) does no probes.
    let flaky = oldSheet()
    let src = source { $0.failDailyFrom = day("2019-01-01") }
    let r11 = await drive(flaky, src)
    var healthy = src; healthy.failDailyFrom = nil     // same probe counter
    let r12 = await drive(flaky, healthy, progress: r11.progress, at: now.addingTimeInterval(3600))
    check(r11.error != nil && r11.progress.rebuildNotBefore != nil && r12.error == nil && src.earliestCalls == 1, "failed_rebuild_backs_off")
    let r13 = await drive(flaky, source(), progress: r11.progress, at: now.addingTimeInterval(RebuildBackoff.interval + 60))
    check(r13.error == nil && r13.progress.historyVersion == HistoryVersion.current && flaky.daily.count >= 3653, "rebuild_retried_after_backoff")

    // The write itself cut short part-way: progress unsaved, the retry completes it cleanly.
    let cut = oldSheet(); cut.failWriteNumber = 3
    let r14 = await drive(cut, source())
    check(r14.error != nil && r14.progress.historyVersion == nil && r14.progress.lastWrittenDay == "2026-09-30", "rebuild_interrupted_write_keeps_progress_unsaved")
    cut.failWriteNumber = nil
    let r15 = await drive(cut, source(), progress: r14.progress, at: now.addingTimeInterval(RebuildBackoff.interval + 60))
    check(r15.error == nil && cut.daily.count == 3653 && Set(cut.daily.map { $0[0] }).count == 3653 && cut.daily.map { $0[0] } == cut.daily.map { $0[0] }.sorted(), "rebuild_recovers_after_interrupted_write")

    // Cancelled mid-prefetch: sheet untouched, and no backoff (iOS took the time, nothing failed).
    let cancelled = oldSheet()
    let r16 = await drive(cancelled, source { $0.cancelDailyFrom = day("2019-01-01") })
    check(r16.error is CancellationError && cancelled.daily == oldRows && r16.progress == oldProgress && saved.isEmpty, "rebuild_cancelled_leaves_sheet_and_no_backoff")

    // The tail clear failing leaves progress unsaved (the rebuild repeats).
    let clearFail = oldSheet(); clearFail.daily = oldRows + Array(repeating: oldRows[0], count: 5000); clearFail.failOp = "clear"
    let r17 = await drive(clearFail, source { $0.earliest = day("2026-08-01") })
    check(r17.error != nil && r17.progress.historyVersion == nil && r17.progress.lastWrittenDay == "2026-09-30", "clear_failure_keeps_progress_unsaved")

    // A person adds a note below the table AFTER the pass read the column: it survives the tail clear.
    let noted = oldSheet(); noted.daily = oldRows + Array(repeating: oldRows[0], count: 5000)
    noted.afterFirstRead = { noted.daily[4000] = ["my notes"] }
    let r18 = await drive(noted, source { $0.earliest = day("2026-08-01") })
    check(r18.error == nil && noted.daily.count > 4000 && noted.daily[4000] == ["my notes"], "tail_clear_spares_rows_added_after_read")

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

    // Fresh connect whose sweep starts years before the first day with data (an old stray
    // sample floored to ten years back): the empty chunks are skipped and the data is written.
    let gap = FakeSheet()
    let g1 = await drive(gap, source { $0.emptyBefore = day("2019-06-01"); $0.workoutDays = [day("2020-01-05")] },
                         progress: SheetsProgress(lastWrittenDay: nil, historyVersion: nil))
    check(g1.error == nil && gap.daily.last?.first == "2026-09-30" && gap.daily.contains { $0.first == "2019-06-01" && $0[1] == "100" },
          "fresh_sweep_skips_empty_leading_chunks")
    check((gap.daily.first?.first ?? "") > "2018-12-01" && gap.workouts.count == 1 && g1.progress.lastWrittenDay == "2026-09-30",
          "fresh_sweep_after_gap_starts_at_first_chunk_with_data")

    // Fresh connect with no data anywhere still fails, with nothing written or saved.
    let none = FakeSheet()
    let g2 = await drive(none, source { $0.emptyBefore = day("2030-01-01"); $0.workoutDays = [] },
                         progress: SheetsProgress(lastWrittenDay: nil, historyVersion: nil))
    check({ if case SheetsError.noHealthData(let checked)? = g2.error { return checked == "2016-09-30 through 2026-09-30 (3653 days)" }; return false }() && none.daily.isEmpty
          && !none.ops.contains("write") && g2.progress.lastWrittenDay == nil && saved.isEmpty, "fresh_sweep_with_no_data_fails_untouched")

    // A day HealthKit refuses to read (support report 2026-10-17: Daily stuck at 2025-03-04 on
    // every pass): the sweep goes on past it to today, and the pass says which cells are blank.
    let stuck = FakeSheet()
    let u1 = await drive(stuck, source { $0.unreadStepDays = [day("2025-03-05"), day("2025-03-06")] },
                         progress: SheetsProgress(lastWrittenDay: nil, historyVersion: nil))
    check(u1.error == nil && stuck.daily.last?.first == "2026-09-30" && u1.progress.lastWrittenDay == "2026-09-30"
          && stuck.daily.contains { $0.first == "2025-03-05" && $0[1] == "" }, "unread_day_does_not_stop_sweep")
    check(lastResult?.unreadCells == ["Steps": ["2025-03-05", "2025-03-06"]] && lastResult?.unreadDays == 2
          && lastResult?.unreadSummary?.contains("Steps on 2 days (2025-03-05 to 2025-03-06)") == true, "unread_cells_reported")
    let rebuiltGap = oldSheet()
    _ = await drive(rebuiltGap, source { $0.unreadStepDays = [day("2020-02-02")] })
    check(lastResult?.unreadCells == ["Steps": ["2020-02-02"]] && rebuiltGap.daily.count == 3653, "unread_cells_reported_by_rebuild")
    // A rebuild refused on a day the sheet already holds keeps that value, matched by date
    // even when the rebuild starts earlier and every row moves down.
    let heldRebuild = oldSheet()
    let heldBefore = heldRebuild.daily.first { $0.first == "2026-09-29" }?[1]
    _ = await drive(heldRebuild, source { $0.unreadStepDays = [day("2026-09-29")]; $0.earliest = day("2016-09-01") })
    let heldAfter = heldRebuild.daily.first { $0.first == "2026-09-29" }
    check(heldBefore == "100" && heldAfter?[1] == "100" && heldRebuild.daily.first?.first == "2016-09-01"
          && lastResult?.unreadPending == ["2026-09-29"], "rebuild_refused_keeps_held_value")
    // A refused day the sheet never held stays blank in a rebuild.
    let newGap = oldSheet()
    _ = await drive(newGap, source { $0.unreadStepDays = [day("2016-09-30")] })
    check(newGap.daily.first { $0.first == "2016-09-30" }?[1] == "", "rebuild_refused_unheld_stays_blank")
    // A row the person inserts while HealthKit is read shifts every row down: the held value
    // still comes from the same date, not from the row that now sits at its old position.
    let edited = oldSheet()
    edited.daily[edited.daily.firstIndex { $0.first == "2026-09-29" }!][1] = "777"
    _ = await drive(edited, source {
        $0.unreadStepDays = [day("2026-09-29")]
        $0.duringDailyRead = { if edited.daily.first?.first != "note" { edited.daily.insert(["note", "5"] + Array(repeating: "", count: 14), at: 0) } }
    })
    check(edited.daily.first { $0.first == "2026-09-29" }?[1] == "777", "rebuild_held_value_survives_mid_pass_edit")
    check(u1.progress.unreadDays == ["2025-03-05", "2025-03-06"], "unread_days_saved_for_retry")

    // Next pass, HealthKit answers again: the blank rows are filled in place and the notice clears.
    let u2 = await drive(stuck, source(), progress: u1.progress, at: now.addingTimeInterval(86_400))
    let row0305 = stuck.daily.first { $0.first == "2025-03-05" }
    check(u2.error == nil && row0305?[1] == "100" && stuck.daily.filter { $0.first == "2025-03-05" }.count == 1
          && u2.progress.unreadDays.isEmpty && lastResult?.unreadSummary == nil, "unread_days_retried_and_filled")
    // Still refused: kept, and the notice shows again on this pass.
    let u3 = await drive(stuck, source { $0.unreadStepDays = [day("2025-03-05"), day("2025-03-06")] },
                         progress: u1.progress, at: now.addingTimeInterval(86_400))
    check(u3.progress.unreadDays == ["2025-03-05", "2025-03-06"] && lastResult?.unreadSummary?.contains("2 days have cells HealthKit would not read") == true,
          "unread_days_kept_while_refused")
    // A long backlog is retried a bounded slice per pass, oldest first; the rest stay pending.
    var backlog = u1.progress
    backlog.unreadDays = DayKey.days(from: day("2024-01-01"), through: day("2024-02-09"), calendar: cal).map { DayKey.string(for: $0, calendar: cal) }
    let u4 = await drive(stuck, source(), progress: backlog, at: now.addingTimeInterval(86_400))
    check(u4.progress.unreadDays.count == 40 - SheetsSyncCore.unreadRetriesPerPass && u4.progress.unreadDays.first == "2024-01-31",
          "unread_backlog_retried_in_bounded_slices")

    // A day that read fine before is refused on a re-read (the overlap): its value is kept,
    // not blanked, and the day is queued for retry.
    let kept = oldSheet()
    let u7 = await drive(kept, source { $0.unreadStepDays = [day("2026-09-29")] }, allowRebuild: false)
    check(u7.error == nil && kept.daily.first { $0.first == "2026-09-29" }?[1] == "100" && u7.progress.unreadDays == ["2026-09-29"],
          "refused_reread_keeps_existing_value")

    // A refused day is saved with the progress that moves past it, so a pass that fails in a
    // later chunk still retries and reports it.
    let cutShort = FakeSheet()
    let u6 = await drive(cutShort, source { $0.unreadStepDays = [day("2017-01-10")]; $0.failDailyFrom = day("2019-01-01") },
                         progress: SheetsProgress(lastWrittenDay: nil, historyVersion: nil))
    check(u6.error != nil && (saved.last?.lastWrittenDay ?? "") >= "2017-01-10" && saved.last?.unreadDays == ["2017-01-10"],
          "unread_saved_before_later_chunk_fails")

    // First sweep: a chunk whose only data was refused is written and tracked, not skipped as empty.
    let refusedOnly = FakeSheet()
    let u5 = await drive(refusedOnly, source { $0.emptyBefore = day("2019-06-01"); $0.unreadStepDays = [day("2017-01-10")] },
                         progress: SheetsProgress(lastWrittenDay: nil, historyVersion: nil))
    check(u5.error == nil && refusedOnly.daily.contains { $0.first == "2017-01-10" } && u5.progress.unreadDays == ["2017-01-10"],
          "refused_only_chunk_not_skipped")

    await runSaveChoiceTests(check, calendar: cal, at: at)
}

/// "What to save": the Sleep stages tab and the Workouts switch.
func runSaveChoiceTests(_ check: (Bool, String) -> Void, calendar cal: Calendar, at: (String) -> Date) async {
    let now = at("2026-09-30T12:00:00-04:00")
    func day(_ k: String) -> Date { cal.startOfDay(for: at("\(k)T12:00:00-04:00")) }
    let current = SheetsProgress(lastWrittenDay: "2026-09-30", historyVersion: HistoryVersion.current)
    func nights(from k: String, through end: String = "2026-09-30") -> [Date] {
        DayKey.days(from: day(k), through: day(end), calendar: cal)
    }
    func source(_ configure: (inout FakeSource) -> Void = { _ in }) -> FakeSource {
        var src = FakeSource(earliest: day("2026-09-01"), calendar: cal, workoutDays: [])
        configure(&src); return src
    }
    func drive(_ sheet: FakeSheet, _ src: FakeSource, progress: SheetsProgress = current, at passNow: Date? = nil,
               _ configure: (inout SheetsSyncCore) -> Void = { $0.saveSleepStages = true })
        async -> (progress: SheetsProgress, error: Error?, result: SheetsPassResult?, saves: Int) {
        var p = progress; var saves = 0
        var core = SheetsSyncCore(api: sheet, source: src, calendar: cal)
        core.rebuildExtras = [("About!A1:B1", [["Column", "Meaning"]])]
        configure(&core)
        do {
            let r = try await core.run(spreadsheetId: "s", progress: &p, allowRebuild: true, now: passNow ?? now) { _ in saves += 1 }
            return (p, nil, r, saves)
        } catch { return (p, error, nil, saves) }
    }
    func ids(_ s: FakeSheet) -> [String] { s.sleep.map { $0[6] } }

    // Off by default: no tab, no request.
    let off = FakeSheet()
    _ = await drive(off, source { $0.sleepNights = nights(from: "2026-09-20") }) { _ in }
    check(!off.ops.contains("ensureTab") && off.sleep.isEmpty && !off.tabs.contains(SheetTabs.sleepStages), "sleep_stages_off_by_default")

    // Switched on for an existing sheet: the tab is added with its header and the About text,
    // and every night since the oldest record is written once, through last night.
    let on = FakeSheet()
    let s1 = await drive(on, source { $0.sleepNights = nights(from: "2026-06-01") })
    check(s1.error == nil && on.tabs.contains(SheetTabs.sleepStages) && on.sleepHeader == SleepStageLayout.header
          && on.about == [["Column", "Meaning"]], "sleep_stages_tab_added_with_header_and_about")
    check(on.sleep.count == 122 * 3 && Set(ids(on)).count == on.sleep.count && on.sleep.first?.first == "2026-06-01"
          && on.sleep.last?.first == "2026-09-30" && s1.result?.sleepStagesAdded == 366, "sleep_stages_first_sweep_complete")
    check(s1.progress.sleepStagesThrough == "2026-09-30" && s1.progress.lastWrittenDay == "2026-09-30", "sleep_stages_progress_saved")

    // The next day: only the new night, and a record that reached Health five nights late
    // (a ring left off the charger), inside the week that is re-read.
    let nextDay = at("2026-10-01T12:00:00-04:00")
    let s2 = await drive(on, source { $0.sleepNights = nights(from: "2026-06-01", through: "2026-10-01"); $0.lateRecords = [day("2026-09-26")] },
                         progress: s1.progress, at: nextDay)
    check(s2.error == nil && on.sleep.count == 122 * 3 + 3 + 1 && Set(ids(on)).count == on.sleep.count
          && s2.progress.sleepStagesThrough == "2026-10-01", "sleep_stages_incremental_adds_new_and_late_once")
    check(on.sleep.allSatisfy { $0.count == 7 }, "sleep_stages_rows_whole")

    // A long history in big nights: appends are chunked, and progress is saved per chunk.
    let big = FakeSheet()
    let s3 = await drive(big, source { $0.sleepNights = nights(from: "2025-01-01"); $0.recordsPerNight = 12 })
    check(s3.error == nil && (big.sleepAppendSizes.max() ?? 0) <= 2000 && big.sleepAppendSizes.count > 4
          && Set(ids(big)).count == big.sleep.count, "sleep_stages_appends_in_chunks")
    check(s3.saves >= 3, "sleep_stages_progress_saved_per_chunk")

    // Cut off part-way: what was written stays, and the next pass finishes with no duplicates.
    let cut = FakeSheet(); cut.failSleepAppendNumber = 3
    let src = source { $0.sleepNights = nights(from: "2025-01-01"); $0.recordsPerNight = 12 }
    let s4 = await drive(cut, src)
    check(s4.error != nil && !cut.sleep.isEmpty && (s4.progress.sleepStagesThrough ?? "") < "2026-09-30", "sleep_stages_interrupted_keeps_progress")
    cut.failSleepAppendNumber = nil
    let s5 = await drive(cut, src, progress: s4.progress)
    check(s5.error == nil && cut.sleep.count == big.sleep.count && Set(ids(cut)).count == cut.sleep.count, "sleep_stages_resume_without_duplicates")

    // The person deleted the tab: it comes back and is filled from the beginning again.
    on.tabs.remove(SheetTabs.sleepStages); on.sleep = []; on.sleepHeader = []
    let s6 = await drive(on, source { $0.sleepNights = nights(from: "2026-06-01") }, progress: s1.progress)
    check(s6.error == nil && on.sleepHeader == SleepStageLayout.header && on.sleep.first?.first == "2026-06-01" && on.sleep.count == 366,
          "sleep_stages_deleted_tab_refilled")

    // No sleep recorded at all: nothing written and nothing marked done.
    let none = FakeSheet()
    let s7 = await drive(none, source())
    check(s7.error == nil && none.sleep.isEmpty && s7.progress.sleepStagesThrough == nil, "sleep_stages_none_not_marked_done")

    // Cut off between adding the tab and writing its header: the next pass writes the header
    // before any record, so no record ever sits in the header row.
    let half = FakeSheet(); half.failWriteNumber = 2   // write 1 is the Daily update
    let h1 = await drive(half, source { $0.sleepNights = nights(from: "2026-09-20") })
    check(h1.error != nil && half.tabs.contains(SheetTabs.sleepStages) && half.sleepHeader.isEmpty && half.sleep.isEmpty, "sleep_stages_header_failure_writes_nothing")
    half.failWriteNumber = nil
    let h2 = await drive(half, source { $0.sleepNights = nights(from: "2026-09-20") }, progress: h1.progress)
    check(h2.error == nil && half.sleepHeader == SleepStageLayout.header && half.sleep.count == 33, "sleep_stages_header_repaired_next_pass")

    // Switched on while a pass was already running: that pass fills it.
    let late = FakeSheet()
    _ = await drive(late, source { $0.sleepNights = nights(from: "2026-09-20") }) {
        $0.saveSleepStages = false
        $0.latestChoices = { SaveChoiceFlags(workouts: true, sleepStages: true, workoutsCatchUp: false) }
    }
    check(late.sleep.count == 33, "sleep_stages_switched_on_mid_pass_filled")

    // Workouts switched off: none added. Switched back on: the ones from while it was off too.
    let w = FakeSheet()
    let wsrc = source { $0.workoutDays = [day("2020-01-05"), day("2026-09-29")] }
    _ = await drive(w, wsrc) { $0.saveWorkouts = false }
    check(w.workouts.isEmpty, "workouts_off_adds_none")
    let wc = await drive(w, wsrc) { $0.workoutsCatchUp = true }
    check(wc.result?.workoutsCaughtUp == true, "workouts_catch_up_reported_done")
    check(w.workouts.count == 2 && w.workouts.first?.first == "2020-01-05", "workouts_catch_up_adds_older")
    _ = await drive(w, wsrc) { _ in }
    check(w.workouts.count == 2, "workouts_merge_never_duplicates")

    // Years of workouts caught up at once: appended in pieces, each whole, none twice.
    let many = FakeSheet()
    let msrc = source { $0.workoutDays = nights(from: "2016-10-01") }   // ~3,650 workouts
    _ = await drive(many, msrc) { $0.workoutsCatchUp = true }
    check(many.workouts.count == msrc.workoutDays.count && (many.workoutAppendSizes.max() ?? 0) <= 2000
          && many.workoutAppendSizes.count >= 2, "workouts_catch_up_appends_in_pieces")
}
