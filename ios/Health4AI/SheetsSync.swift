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
    case noHealthData
    /// iOS has never been asked for some type the daily summary reads. Unlike a denial this
    /// makes HealthKit throw, so it gets its own fix: ask, then sync.
    case healthNotAsked
    case http(status: Int, detail: String)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .spreadsheetMissing: return "Your health4ai sheet was deleted or moved out of reach."
        case .noHealthData: return "No health data found to add to your sheet."
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
}

struct SheetsPassResult {
    var daysWritten: Int
    var workoutsAdded: Int
    /// A due history rebuild was not run because it would have destroyed rows (Health access
    /// for the older history is off). The incremental work still succeeded.
    var rebuildSkipped = false
}

/// The two fields of the saved sheet state that sequencing reads and advances.
struct SheetsProgress: Equatable {
    var lastWrittenDay: String?
    var historyVersion: Int?
    /// No rebuild attempt before this time (set when one fails or is refused).
    var rebuildNotBefore: Date?
}

protocol SheetsAPI {
    func readDateColumn(spreadsheetId: String, range: String) async throws -> [String]
    func readColumn(spreadsheetId: String, range: String) async throws -> [String]
    func writeRanges(spreadsheetId: String, _ ranges: [(range: String, rows: [[String]])]) async throws
    func append(spreadsheetId: String, range: String, rows: [[String]]) async throws
    func clear(spreadsheetId: String, ranges: [String]) async throws
    func ensureRows(spreadsheetId: String, tab: String, needed: Int, headroom: Int) async throws -> Int
}

/// Where the rows come from (HealthKit, with the sheet's units already bound).
protocol SheetsHistorySource {
    func earliestDataDay(now: Date) async throws -> Date
    func dailyRows(from: Date, through: Date) async throws -> [[String]]
    func workoutRows(from: Date, to: Date) async throws -> [[String]]
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

    /// One pass. `allowRebuild` is false in the background: a rebuild is ~20 chunks of
    /// HealthKit queries and a single write, which a background window cannot be trusted to
    /// finish, and a failure must not stall the ordinary incremental updates.
    func run(spreadsheetId id: String, progress: inout SheetsProgress, allowRebuild: Bool,
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
                    persist(progress)
                    return rebuilt
                }
            } catch is CancellationError {
                throw CancellationError()   // iOS took the time back: not a failure to back off from
            } catch {
                progress.rebuildNotBefore = now.addingTimeInterval(RebuildBackoff.interval)
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
        var gridRows = 0
        var workoutsDone = false
        var chunkStart = start
        while chunkStart <= today {
            try Task.checkCancellation()
            let chunkEnd = min(calendar.date(byAdding: .day, value: Self.chunkDays - 1, to: chunkStart)!, today)
            let rows = try await source.dailyRows(from: chunkStart, through: chunkEnd)
            // First connect with nothing to write: do not report success and do not advance
            // lastWrittenDay over it (Reviewboard B, 2026-09-28).
            if pendingFirstWrite, !Self.hasData(rows) { throw SheetsError.noHealthData }
            if pendingFirstWrite {
                // One growth request sized for the whole sweep, instead of one per chunk.
                let days = (calendar.dateComponents([.day], from: start, to: today).day ?? 0) + 1
                gridRows = try await api.ensureRows(spreadsheetId: id, tab: SheetTabs.daily,
                                                    needed: existing.count + 1 + days, headroom: Self.gridHeadroom)
                // Workouts first: a sweep cut short resumes from a recent day and would never
                // come back for older workouts.
                result.workoutsAdded += try await addWorkouts(id: id, from: start, today: today)
                workoutsDone = true
            }
            let plan = UpsertPlan.make(existingDates: existing, rows: rows)
            var ranges = plan.updates.map { (range: "\(SheetTabs.daily)!A\($0.row):P\($0.row)", rows: [$0.values]) }
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
            progress.lastWrittenDay = DayKey.string(for: chunkEnd, calendar: calendar)
            if pendingFirstWrite { progress.historyVersion = HistoryVersion.current }
            pendingFirstWrite = false
            persist(progress)
            chunkStart = calendar.date(byAdding: .day, value: 1, to: chunkEnd)!
        }
        if !workoutsDone { result.workoutsAdded += try await addWorkouts(id: id, from: start, today: today) }
        // The incremental work above is done and saved; the sheet keeps its old history.
        result.rebuildSkipped = rebuildRefused
        return result
    }

    static let writeChunkRows = 800

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
        var chunkStart = start
        while chunkStart <= today {
            try Task.checkCancellation()
            let chunkEnd = min(calendar.date(byAdding: .day, value: Self.chunkDays - 1, to: chunkStart)!, today)
            daily += try await source.dailyRows(from: chunkStart, through: chunkEnd)
            chunkStart = calendar.date(byAdding: .day, value: 1, to: chunkEnd)!
        }
        guard Self.hasData(daily) else { throw SheetsError.noHealthData }
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

        let added = try await addWorkouts(id: id, from: start, today: today)
        try await tidyWorkoutNames(id: id)
        return SheetsPassResult(daysWritten: daily.count, workoutsAdded: added)
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
        try await api.append(spreadsheetId: id, range: "\(SheetTabs.workouts)!A:H", rows: fresh)
        return fresh.count
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
