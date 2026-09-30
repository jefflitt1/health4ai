#if H4A_SHEETS
// Compiled only with H4A_SHEETS (off in Release by default; see docs/sheets-build-gate.md).
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
}

/// The two fields of the saved sheet state that sequencing reads and advances.
struct SheetsProgress: Equatable {
    var lastWrittenDay: String?
    var historyVersion: Int?
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
    /// Written in the same atomic request as a rebuild (the About tab's current text).
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

        if allowRebuild, HistoryVersion.needsRebuild(lastWrittenDay: progress.lastWrittenDay,
                                                     historyVersion: progress.historyVersion) {
            let start = try await source.earliestDataDay(now: now)
            // A start later than the sheet's first row means some types came back without
            // their older history (Health access off). Rebuilding would destroy those rows.
            let firstHeld = existing.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.min()
            if let firstHeld, DayKey.string(for: start, calendar: calendar) > firstHeld {
                rebuildRefused = true
            } else {
                let rebuilt = try await rebuild(id: id, from: start, today: today, existingCount: existing.count)
                progress.lastWrittenDay = DayKey.string(for: today, calendar: calendar)
                progress.historyVersion = HistoryVersion.current
                persist(progress)
                return rebuilt
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
        // The incremental work above is done and saved; the sheet still has the old history.
        if rebuildRefused { throw SheetsError.noHealthData }
        return result
    }

    /// Rebuilds both data tabs from `start`. Everything failure-prone (HealthKit queries, row
    /// count, grid growth) happens BEFORE the sheet is touched; the rows then go in one
    /// atomic `values:batchUpdate` that overwrites in place. There is never a moment with the
    /// tabs cleared and the new rows not yet there. Rows left over from a longer old tab are
    /// cleared last; if that fails the stale tail is overwritten by the next rebuild.
    private func rebuild(id: String, from start: Date, today: Date, existingCount: Int) async throws -> SheetsPassResult {
        var daily: [[String]] = []
        var chunkStart = start
        while chunkStart <= today {
            try Task.checkCancellation()
            let chunkEnd = min(calendar.date(byAdding: .day, value: Self.chunkDays - 1, to: chunkStart)!, today)
            daily += try await source.dailyRows(from: chunkStart, through: chunkEnd)
            chunkStart = calendar.date(byAdding: .day, value: 1, to: chunkEnd)!
        }
        guard Self.hasData(daily) else { throw SheetsError.noHealthData }
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
        let workouts = try await source.workoutRows(from: start, to: tomorrow)
        let oldWorkouts = try await api.readColumn(spreadsheetId: id, range: "\(SheetTabs.workouts)!H2:H").count

        _ = try await api.ensureRows(spreadsheetId: id, tab: SheetTabs.daily, needed: daily.count + 1, headroom: Self.gridHeadroom)
        _ = try await api.ensureRows(spreadsheetId: id, tab: SheetTabs.workouts, needed: workouts.count + 1, headroom: Self.gridHeadroom)

        var ranges = [(range: "\(SheetTabs.daily)!A2:P\(daily.count + 1)", rows: daily)]
        if !workouts.isEmpty { ranges.append((range: "\(SheetTabs.workouts)!A2:H\(workouts.count + 1)", rows: workouts)) }
        try await api.writeRanges(spreadsheetId: id, ranges + rebuildExtras)

        var tails: [String] = []
        if existingCount > daily.count { tails.append("\(SheetTabs.daily)!A\(daily.count + 2):P\(existingCount + 1)") }
        if oldWorkouts > workouts.count { tails.append("\(SheetTabs.workouts)!A\(workouts.count + 2):H\(oldWorkouts + 1)") }
        if !tails.isEmpty { try await api.clear(spreadsheetId: id, ranges: tails) }
        return SheetsPassResult(daysWritten: daily.count, workoutsAdded: workouts.count)
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
