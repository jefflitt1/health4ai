#if H4A_SHEETS
// Compiled only with H4A_SHEETS (on in Debug and Release since 1.0.1; see docs/sheets-build-gate.md).
import Foundation

// The Google Sheets destination's pass sequencing, with no HealthKit, network or UI in it.
// SheetsSink wires the real client and HealthKit builder in; scripts/SheetsSyncTests.swift
// drives the same code with fakes, so the order of "read, build, write, clear, save
// progress" is tested, not just the helpers it calls.

enum SheetsError: LocalizedError {
    /// The spreadsheet is gone: deleted, trashed, or (drive.file) no longer visible to the app.
    case spreadsheetMissing
    /// A first sync found no health data at all. HealthKit reports a DENIED read as an empty
    /// result, so this is usually missing Health access, not an empty history; treating it as
    /// success is how this app once showed a green "Complete" for three months with no data.
    /// `checked` says which days were read, so Sync History carries it for support (2026-10-09).
    case noHealthData(checked: String)
    /// iOS has never been asked for some type the daily summary reads. Unlike a denial this
    /// makes HealthKit throw, so it gets its own fix: ask, then sync.
    case healthNotAsked
    case http(status: Int, detail: String)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .spreadsheetMissing: return "Your health4ai sheet was deleted or moved out of reach."
        case .noHealthData(let checked): return "No health data found to add to your sheet. Checked \(checked)."
        case .healthNotAsked: return "health4ai has not yet asked for all the Health data your sheet uses."
        case .http(let status, _): return "Google Sheets returned an error (HTTP \(status))."
        case .badResponse: return "Google Sheets returned an unexpected response."
        }
    }
}

enum SheetTabs {
    static let daily = "Daily"
    static let workouts = "Workouts"
    static let about = "About"
    static let sleepStages = "Sleep stages"

    /// "'Sleep stages'!A2:A". A tab name with a space must be quoted in A1 notation; the
    /// quotes are harmless on the others, but they are left bare to keep existing ranges as-is.
    static func range(_ tab: String, _ cells: String) -> String {
        tab.contains(" ") ? "'\(tab)'!\(cells)" : "\(tab)!\(cells)"
    }
}

/// One chunk of Daily rows, and the cells HealthKit refused to read for it (left blank).
struct DailyChunk {
    var rows: [[String]]
    /// Column label ("Steps") -> the day keys whose cell could not be read.
    var unread: [String: [String]] = [:]

    /// Daily tab columns (0 = A) HealthKit refused for the day `key`.
    func refusedColumns(on key: String) -> Set<Int> {
        Set(unread.compactMap { $0.value.contains(key) ? DailyColumn.index[$0.key] : nil })
    }
}

enum DailyColumn {
    /// The Daily column (0 = A, the date) of each label a DailyChunk can report unread.
    static let index: [String: Int] = [
        "Steps": 1, "Distance": 2, "Active energy": 3, "Exercise": 4, "Flights climbed": 6,
        "Resting HR": 7, "Avg HR": 8, "HRV": 9, "Weight": 14, "VO2 max": 15]

    /// Ranges that rewrite an existing Daily row with `values`, leaving out the `refused`
    /// columns: a refused read is not "no data", so the value already in the sheet is kept
    /// rather than blanked (the same rule as never clearing Workouts on an empty read).
    static func rewrite(row: Int, values: [String], refused: Set<Int>) -> [(range: String, rows: [[String]])] {
        guard !refused.isEmpty else { return [("\(SheetTabs.daily)!A\(row):P\(row)", [values])] }
        var out: [(range: String, rows: [[String]])] = []
        var start: Int?
        for i in 0...values.count {
            if i < values.count, !refused.contains(i) { if start == nil { start = i }; continue }
            if let s = start {
                out.append(("\(SheetTabs.daily)!\(letter(s))\(row):\(letter(i - 1))\(row)", [Array(values[s..<i])]))
                start = nil
            }
        }
        return out
    }

    static func letter(_ i: Int) -> String { String(UnicodeScalar(UInt8(65 + i))) }
}

struct SheetsPassResult {
    var daysWritten: Int
    var workoutsAdded: Int
    var sleepStagesAdded = 0
    /// Column label -> day keys HealthKit could not read this pass. Those cells are written
    /// blank, and the About tab says blank means no data, so this must reach the person.
    var unreadCells: [String: [String]] = [:]

    mutating func addUnread(_ more: [String: [String]]) {
        for (label, days) in more { unreadCells[label, default: []] += days }
    }

    /// Every day still carrying a blank HealthKit refused, after this pass (saved as
    /// SheetsProgress.unreadDays), including earlier refusals this pass did not reach.
    var unreadPending: [String] = []

    /// Distinct days still carrying an unread cell.
    var unreadDays: Int { unreadPending.count }

    /// For the Sheets card, e.g. "HealthKit could not read Steps on 1 day (2025-03-05). ...".
    /// Shown on every pass while any day is pending, not only the pass that met it, because
    /// the About tab tells the reader a blank means no data.
    var unreadSummary: String? {
        guard !unreadPending.isEmpty else { return nil }
        let parts = unreadCells.keys.sorted().map { label -> String in
            let days = Set(unreadCells[label]!).sorted()
            let span = days.count == 1 ? days[0] : "\(days.first!) to \(days.last!)"
            return "\(label) on \(days.count) day\(days.count == 1 ? "" : "s") (\(span))"
        }
        let detail = parts.isEmpty ? "" : "HealthKit could not read \(parts.joined(separator: ", ")). "
        let n = unreadPending.count
        return detail + "\(n) day\(n == 1 ? " has" : "s have") blank cells HealthKit would not read; health4ai asks again on each sync and fills them in when it can."
    }
    /// Every workout was merged, so the person's "catch up" request is done.
    var workoutsCaughtUp = false
    /// A due history rebuild was not run because it would have destroyed rows (Health access
    /// for the older history is off). The incremental work still succeeded.
    var rebuildSkipped = false
}

/// What to save, as the sync core sees it (SheetsSaveChoices without the storage).
struct SaveChoiceFlags {
    var workouts: Bool
    var sleepStages: Bool
    var workoutsCatchUp: Bool
}

/// The two fields of the saved sheet state that sequencing reads and advances.
struct SheetsProgress: Equatable {
    var lastWrittenDay: String?
    var historyVersion: Int?
    /// No rebuild attempt before this time (set when one fails or is refused).
    var rebuildNotBefore: Date?
    /// Last night fully written to the Sleep stages tab; nil before its first sweep. Kept
    /// apart from `lastWrittenDay` because the tab can be switched on long after the sheet
    /// was made, and only advances while it is on, so switching it back on fills the gap.
    var sleepStagesThrough: String?
    /// Day keys whose Daily row has a cell HealthKit refused to read (RangeSplit). Asked again
    /// on later passes, because the refusal is a stale HealthKit cache that can clear.
    var unreadDays: [String] = []
    /// Set (not persisted) when this pass attempted a history rebuild and it threw, so the
    /// caller can tell a failed rebuild from an incremental failure after a refusal.
    var rebuildFailed = false
}

protocol SheetsAPI {
    func readDateColumn(spreadsheetId: String, range: String) async throws -> [String]
    func readColumn(spreadsheetId: String, range: String) async throws -> [String]
    func writeRanges(spreadsheetId: String, _ ranges: [(range: String, rows: [[String]])]) async throws
    func append(spreadsheetId: String, range: String, rows: [[String]]) async throws
    func clear(spreadsheetId: String, ranges: [String]) async throws
    func ensureRows(spreadsheetId: String, tab: String, needed: Int, headroom: Int) async throws -> Int
    /// Adds the tab (with a frozen header row) if the sheet has none by that name. True when
    /// it was added, so the caller writes the header.
    func ensureTab(spreadsheetId: String, title: String) async throws -> Bool
}

/// Where the rows come from (HealthKit, with the sheet's units already bound).
protocol SheetsHistorySource {
    func earliestDataDay(now: Date) async throws -> Date
    func dailyRows(from: Date, through: Date) async throws -> DailyChunk
    func workoutRows(from: Date, to: Date) async throws -> [[String]]
    /// Start of the oldest sleep record, nil when there is none.
    func oldestSleepRecord() async throws -> Date?
    /// Sleep stages tab rows for the nights `from` through `through` (by `SleepMath.night`),
    /// each record once, ordered by start.
    func sleepStageRows(nights from: Date, through: Date) async throws -> [[String]]
}

struct SheetsSyncCore {
    static let chunkDays = 180
    static let overlapDays = 2
    /// Spare rows when a tab grows, so the growth is one request, not one per chunk.
    static let gridHeadroom = 500

    let api: SheetsAPI
    let source: SheetsHistorySource
    let calendar: Calendar
    /// Rewritten with a rebuild (the About tab's current text).
    var rebuildExtras: [(range: String, rows: [[String]])] = []
    /// What to save (the person's choices). The Daily tab is always written: its column A is
    /// how a pass knows where the sheet is up to.
    var saveWorkouts = true
    var saveSleepStages = false
    /// Workouts were just switched back on: merge every workout, not only the recent days,
    /// so the ones recorded while it was off are not left out.
    var workoutsCatchUp = false
    /// The choices as saved right now, read after the Daily part of the pass.
    var latestChoices: (() -> SaveChoiceFlags)?

    /// One pass. `allowRebuild` is false in the background: a rebuild is ~20 chunks of
    /// HealthKit queries and a single write, which a background window cannot be trusted to
    /// finish, and a failure must not stall the ordinary incremental updates.
    func run(spreadsheetId id: String, progress: inout SheetsProgress, allowRebuild: Bool,
             now: Date, persist: (SheetsProgress) -> Void) async throws -> SheetsPassResult {
        var result = try await syncDaily(spreadsheetId: id, progress: &progress, allowRebuild: allowRebuild,
                                         now: now, persist: persist)
        let today = calendar.startOfDay(for: now)
        // Re-read now: a choice switched on while the Daily part ran (often a long first sweep)
        // is acted on in this pass, because the switch's own sync is skipped as in-flight.
        let latest = latestChoices?() ?? SaveChoiceFlags(workouts: saveWorkouts, sleepStages: saveSleepStages,
                                                         workoutsCatchUp: workoutsCatchUp)
        if latest.workouts && latest.workoutsCatchUp {
            result.workoutsAdded += try await addWorkouts(id: id, from: Self.historyFloor(today, calendar: calendar), today: today)
            result.workoutsCaughtUp = true
        }
        if latest.sleepStages {
            result.sleepStagesAdded = try await syncSleepStages(id: id, progress: &progress, today: today, persist: persist)
        }
        return result
    }

    /// The oldest day any sweep goes back to, so a first sync always finishes.
    static func historyFloor(_ today: Date, calendar: Calendar) -> Date {
        calendar.date(byAdding: .year, value: -10, to: today)!
    }

    /// Workouts switched off: none added. Catching up: `run` merges them all afterwards.
    private var mergeRecentWorkouts: Bool { saveWorkouts && !workoutsCatchUp }

    /// The Daily tab (rebuild or incremental) and, unless switched off, recent workouts.
    private func syncDaily(spreadsheetId id: String, progress: inout SheetsProgress, allowRebuild: Bool,
                           now: Date, persist: (SheetsProgress) -> Void) async throws -> SheetsPassResult {
        let today = calendar.startOfDay(for: now)
        var existing = try await api.readDateColumn(spreadsheetId: id, range: "\(SheetTabs.daily)!A2:A")
        var result = SheetsPassResult(daysWritten: 0, workoutsAdded: 0)
        var rebuildRefused = false

        if allowRebuild, !RebuildBackoff.isBlocked(notBefore: progress.rebuildNotBefore, now: now),
           HistoryVersion.needsRebuild(lastWrittenDay: progress.lastWrittenDay, historyVersion: progress.historyVersion) {
            do {
                let start = try await source.earliestDataDay(now: now)
                // A start later than the sheet's first real row means some types came back
                // without their older history (Health access off). Rebuilding would destroy
                // those rows, so the rebuild is skipped, not failed.
                if let firstHeld = DateKeys.earliestHeld(existing), DayKey.string(for: start, calendar: calendar) > firstHeld {
                    rebuildRefused = true
                    progress.rebuildNotBefore = now.addingTimeInterval(RebuildBackoff.interval)
                    persist(progress)
                } else {
                    let rebuilt = try await rebuild(id: id, from: start, today: today)
                    progress.lastWrittenDay = DayKey.string(for: today, calendar: calendar)
                    progress.historyVersion = HistoryVersion.current
                    progress.rebuildNotBefore = nil
                    progress.unreadDays = rebuilt.unreadPending
                    persist(progress)
                    return rebuilt
                }
            } catch is CancellationError {
                throw CancellationError()   // iOS took the time back: not a failure to back off from
            } catch {
                progress.rebuildNotBefore = now.addingTimeInterval(RebuildBackoff.interval)
                progress.rebuildFailed = true
                persist(progress)
                throw error
            }
        }

        let resumeFrom = progress.lastWrittenDay.flatMap { Self.date(fromKey: $0, calendar: calendar) }
        let freshSweep = progress.lastWrittenDay == nil
        let start: Date
        if let resumeFrom {
            start = min(calendar.date(byAdding: .day, value: -Self.overlapDays, to: resumeFrom)!, today)
        } else {
            start = try await source.earliestDataDay(now: now)
        }

        var pendingFirstWrite = freshSweep
        var firstDay = start
        var gridRows = 0
        var workoutsDone = false
        var chunkStart = start
        while chunkStart <= today {
            try Task.checkCancellation()
            let chunkEnd = min(calendar.date(byAdding: .day, value: Self.chunkDays - 1, to: chunkStart)!, today)
            let chunk = try await source.dailyRows(from: chunkStart, through: chunkEnd)
            let rows = chunk.rows
            // First connect with nothing to write: do not report success and do not advance
            // lastWrittenDay over it (Reviewboard B, 2026-09-28). An empty chunk with later
            // days still to read is skipped, not failed: the sweep can start well before the
            // first day with data (an oldest sample past the ten-year floor, then a gap), and
            // failing there told someone with years of data they had none (2026-10-09).
            if pendingFirstWrite, !Self.hasData(rows), chunk.unread.isEmpty {
                guard chunkEnd < today else {
                    throw SheetsError.noHealthData(checked: Self.checkedRange(start, today, calendar: calendar))
                }
                chunkStart = calendar.date(byAdding: .day, value: 1, to: chunkEnd)!
                firstDay = chunkStart
                continue
            }
            if pendingFirstWrite {
                // One growth request sized for the whole sweep, instead of one per chunk.
                let days = (calendar.dateComponents([.day], from: firstDay, to: today).day ?? 0) + 1
                gridRows = try await api.ensureRows(spreadsheetId: id, tab: SheetTabs.daily,
                                                    needed: existing.count + 1 + days, headroom: Self.gridHeadroom)
                // Workouts first: a sweep cut short resumes from a recent day and would never
                // come back for older workouts.
                if mergeRecentWorkouts { result.workoutsAdded += try await addWorkouts(id: id, from: firstDay, today: today) }
                workoutsDone = true
            }
            let plan = UpsertPlan.make(existingDates: existing, rows: rows)
            var ranges = plan.updates.flatMap {
                DailyColumn.rewrite(row: $0.row, values: $0.values, refused: chunk.refusedColumns(on: $0.values[0]))
            }
            if !plan.appends.isEmpty {
                let firstRow = existing.count + 2
                let lastRow = firstRow + plan.appends.count - 1
                // Guard only: the sweep-start growth normally covers this, and a tab still inside
                // Google's default height needs no request at all.
                if lastRow > max(gridRows, GridGrowth.defaultRows) {
                    gridRows = try await api.ensureRows(spreadsheetId: id, tab: SheetTabs.daily,
                                                        needed: lastRow, headroom: Self.gridHeadroom)
                }
                ranges.append((range: "\(SheetTabs.daily)!A\(firstRow):P\(lastRow)", rows: plan.appends))
                existing += plan.appends.map { $0[0] }
            }
            try await api.writeRanges(spreadsheetId: id, ranges)
            result.daysWritten += rows.count
            result.addUnread(chunk.unread)
            // Saved with the lastWrittenDay that moves past them, so a pass cut short later
            // cannot leave blank days that are neither retried nor reported.
            progress.unreadDays = Set(progress.unreadDays).union(chunk.unread.values.joined()).sorted()
            progress.lastWrittenDay = DayKey.string(for: chunkEnd, calendar: calendar)
            if pendingFirstWrite { progress.historyVersion = HistoryVersion.current }
            pendingFirstWrite = false
            persist(progress)
            chunkStart = calendar.date(byAdding: .day, value: 1, to: chunkEnd)!
        }
        try await retryUnread(id: id, before: start, existing: existing, progress: &progress, result: &result)
        persist(progress)
        if !workoutsDone && mergeRecentWorkouts { result.workoutsAdded += try await addWorkouts(id: id, from: start, today: today) }
        // The incremental work above is done and saved; the sheet keeps its old history.
        result.rebuildSkipped = rebuildRefused
        return result
    }

    static let writeChunkRows = 800
    /// Earlier refused days asked again per pass, oldest first, so a type HealthKit refuses for
    /// months cannot turn every pass (background ones too) into hundreds of queries.
    static let unreadRetriesPerPass = 30

    /// Re-reads days refused on an earlier pass that this pass's sweep (from `sweepStart`) did
    /// not cover, rewrites their rows in place, and leaves `progress.unreadDays` as what is
    /// still unread: this pass's refusals, retries refused again, and retries not reached.
    private func retryUnread(id: String, before sweepStart: Date, existing: [String],
                             progress: inout SheetsProgress, result: inout SheetsPassResult) async throws {
        let swept = DayKey.string(for: sweepStart, calendar: calendar)
        let earlier = progress.unreadDays.filter { $0 < swept }.sorted()
        let tried = earlier.prefix(Self.unreadRetriesPerPass)
        var ranges: [(range: String, rows: [[String]])] = []
        for key in tried {
            try Task.checkCancellation()
            guard let day = Self.date(fromKey: key, calendar: calendar) else { continue }
            let chunk = try await source.dailyRows(from: day, through: day)
            result.addUnread(chunk.unread)
            // Only rows the tab still holds are rewritten; a row the person removed is left out.
            ranges += UpsertPlan.make(existingDates: existing, rows: chunk.rows).updates.flatMap {
                DailyColumn.rewrite(row: $0.row, values: $0.values, refused: chunk.refusedColumns(on: $0.values[0]))
            }
        }
        if !ranges.isEmpty { try await api.writeRanges(spreadsheetId: id, ranges) }
        result.unreadPending = Set(result.unreadCells.values.joined()).union(earlier.dropFirst(tried.count)).sorted()
        progress.unreadDays = result.unreadPending
    }

    /// Rebuilds the Daily tab from `start` and merges the Workouts tab. Everything
    /// failure-prone (HealthKit queries, grid growth) happens BEFORE the sheet is touched.
    /// Daily is then overwritten in place, `writeChunkRows` rows per request, so there is never
    /// a moment with the tab cleared; correctness does not rely on Google applying several
    /// ranges of one request all-or-nothing (its docs do not promise it): a rebuild cut short
    /// leaves progress unsaved, and the next one overwrites the same rows again. Workouts are
    /// NEVER cleared or overwritten, because a denied or empty HealthKit read returns no
    /// workouts and would otherwise erase the person's history; they are merged by ID, and
    /// raw "HKWorkoutActivityType..." names from builds 54-55 are tidied in place.
    private func rebuild(id: String, from start: Date, today: Date) async throws -> SheetsPassResult {
        var daily: [[String]] = []
        var unread = SheetsPassResult(daysWritten: 0, workoutsAdded: 0)
        var chunkStart = start
        while chunkStart <= today {
            try Task.checkCancellation()
            let chunkEnd = min(calendar.date(byAdding: .day, value: Self.chunkDays - 1, to: chunkStart)!, today)
            let chunk = try await source.dailyRows(from: chunkStart, through: chunkEnd)
            daily += chunk.rows
            unread.addUnread(chunk.unread)
            chunkStart = calendar.date(byAdding: .day, value: 1, to: chunkEnd)!
        }
        guard Self.hasData(daily) else { throw SheetsError.noHealthData(checked: Self.checkedRange(start, today, calendar: calendar)) }
        try Task.checkCancellation()

        _ = try await api.ensureRows(spreadsheetId: id, tab: SheetTabs.daily, needed: daily.count + 1, headroom: Self.gridHeadroom)
        var row = 2
        while row - 2 < daily.count {
            try Task.checkCancellation()
            let slice = Array(daily[(row - 2)..<min(row - 2 + Self.writeChunkRows, daily.count)])
            try await api.writeRanges(spreadsheetId: id, [("\(SheetTabs.daily)!A\(row):P\(row + slice.count - 1)", slice)])
            row += slice.count
        }
        if !rebuildExtras.isEmpty { try await api.writeRanges(spreadsheetId: id, rebuildExtras) }

        // Rows below the rebuilt table: re-read now (the pass-start snapshot is stale) and clear
        // only rows whose column A is a date key this app wrote. A person's text is left.
        let current = try await api.readDateColumn(spreadsheetId: id, range: "\(SheetTabs.daily)!A2:A")
        let stale = DateKeys.staleRuns(current, keptRows: daily.count + 1)
        if !stale.isEmpty {
            try await api.clear(spreadsheetId: id, ranges: stale.map { "\(SheetTabs.daily)!A\($0.lowerBound):P\($0.upperBound)" })
        }

        let added = mergeRecentWorkouts ? try await addWorkouts(id: id, from: start, today: today) : 0
        try await tidyWorkoutNames(id: id)
        var out = SheetsPassResult(daysWritten: daily.count, workoutsAdded: added, unreadCells: unread.unreadCells)
        out.unreadPending = Set(unread.unreadCells.values.joined()).sorted()
        return out
    }

    /// Rewrites only the Type cell of rows still carrying a raw HealthKit identifier.
    private func tidyWorkoutNames(id: String) async throws {
        let types = try await api.readColumn(spreadsheetId: id, range: "\(SheetTabs.workouts)!C2:C")
        let fixes = types.enumerated().compactMap { i, t -> (range: String, rows: [[String]])? in
            guard t.hasPrefix("HKWorkoutActivityType") else { return nil }
            return ("\(SheetTabs.workouts)!C\(i + 2)", [[WorkoutName.display(fromIdentifier: t)]])
        }
        if !fixes.isEmpty { try await api.writeRanges(spreadsheetId: id, fixes) }
    }

    /// Appends only workout IDs the tab does not hold, so a repeated or interrupted pass
    /// never duplicates a row. Returns how many were added.
    private func addWorkouts(id: String, from start: Date, today: Date) async throws -> Int {
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
        let rows = try await source.workoutRows(from: start, to: tomorrow)
        guard !rows.isEmpty else { return 0 }
        let known = Set(try await api.readColumn(spreadsheetId: id, range: "\(SheetTabs.workouts)!H2:H"))
        let fresh = rows.filter { !known.contains($0[7]) }
        // In pieces: a catch-up after years with the switch off can be thousands of workouts.
        try await appendInPieces(id: id, range: "\(SheetTabs.workouts)!A:H", rows: fresh)
        return fresh.count
    }

    static func checkedRange(_ start: Date, _ end: Date, calendar: Calendar) -> String {
        let days = (calendar.dateComponents([.day], from: start, to: end).day ?? 0) + 1
        return "\(DayKey.string(for: start, calendar: calendar)) through \(DayKey.string(for: end, calendar: calendar)) (\(days) days)"
    }

    private static func hasData(_ rows: [[String]]) -> Bool {
        rows.contains { $0.dropFirst().contains { !$0.isEmpty } }
    }

    static func date(fromKey key: String, calendar: Calendar) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}
#endif
