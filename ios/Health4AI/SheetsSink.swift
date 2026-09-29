import Foundation
import HealthKit
import os

// The Google Sheets destination's sync pass. In Sheets mode SyncEngine.runFullPass calls
// this instead of the Supabase upload, so it inherits the same triggers (launch, foreground,
// HKObserverQuery background delivery, BGAppRefreshTask) and the same in-flight guard.

/// Persisted state for the person's sheet. UserDefaults, not Keychain: none of it is a
/// secret (the sheet is only reachable with their Google sign-in).
struct SheetsDestinationState: Codable, Equatable {
    var spreadsheetId: String
    var spreadsheetURL: String
    var units: SheetUnits
    /// Last day fully written to the Daily tab. The next pass rebuilds from two days before
    /// it, because a Watch or ring often syncs yesterday's data into Health hours late.
    var lastWrittenDay: String?

    private static let key = "hkb.sheetsDestination"

    static func load() -> SheetsDestinationState? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(SheetsDestinationState.self, from: data)
    }

    func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(self), forKey: Self.key)
    }

    static func clear() { UserDefaults.standard.removeObject(forKey: key) }
}

struct SheetsPassResult {
    var daysWritten: Int
    var workoutsAdded: Int
}

final class SheetsSink: @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.jglittell.health4ai", category: "SheetsSink")
    /// Days per write on a first sync. Bounds memory for decade-long histories and saves
    /// progress between chunks, so a pass iOS cuts short resumes where it stopped.
    private static let chunkDays = 180
    private static let rebuildOverlapDays = 2

    private let builder: DailySummaryBuilder
    private let client: SheetsClient
    private let store: HKHealthStore
    private let calendar: Calendar

    init(store: HKHealthStore, client: SheetsClient = .shared, calendar: Calendar = .current) {
        self.store = store
        self.client = client
        self.calendar = calendar
        self.builder = DailySummaryBuilder(store: store, calendar: calendar)
    }

    /// Creates the sheet if there is none, then brings it up to date through today.
    func run(now: Date = Date()) async throws -> SheetsPassResult {
        guard GoogleTokenStore.shared.isSignedIn else { throw GoogleAuthError.notSignedIn }
        var state: SheetsDestinationState
        if let saved = SheetsDestinationState.load() {
            state = saved
        } else {
            state = try await createSheet()
        }

        let today = calendar.startOfDay(for: now)
        let start: Date
        if let last = state.lastWrittenDay, let lastDay = Self.date(fromKey: last, calendar: calendar) {
            start = min(calendar.date(byAdding: .day, value: -Self.rebuildOverlapDays, to: lastDay)!, today)
        } else {
            start = await builder.earliestDataDay(now: now)
        }

        var result = SheetsPassResult(daysWritten: 0, workoutsAdded: 0)
        do {
            var existing = try await client.readColumn(spreadsheetId: state.spreadsheetId, range: "\(SheetLayout.dailyTab)!A2:A")
            var chunkStart = start
            while chunkStart <= today {
                try Task.checkCancellation()
                let chunkEnd = min(calendar.date(byAdding: .day, value: Self.chunkDays - 1, to: chunkStart)!, today)
                let rows = try await builder.dailyRows(from: chunkStart, through: chunkEnd, units: state.units)
                let plan = UpsertPlan.make(existingDates: existing, rows: rows)
                var ranges = plan.updates.map { (range: Self.dailyRange(row: $0.row), rows: [$0.values]) }
                if !plan.appends.isEmpty {
                    let firstRow = existing.count + 2
                    ranges.append((range: "\(SheetLayout.dailyTab)!A\(firstRow):P\(firstRow + plan.appends.count - 1)",
                                   rows: plan.appends))
                    existing += plan.appends.map { $0[0] }
                }
                try await client.writeRanges(spreadsheetId: state.spreadsheetId, ranges)
                result.daysWritten += rows.count
                state.lastWrittenDay = DayKey.string(for: chunkEnd, calendar: calendar)
                state.save()
                chunkStart = calendar.date(byAdding: .day, value: 1, to: chunkEnd)!
            }

            // Workouts: append only IDs the tab does not already hold, so a repeated or
            // interrupted pass never duplicates a row.
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
            let workoutRows = try await builder.workoutRows(from: start, to: tomorrow, units: state.units)
            if !workoutRows.isEmpty {
                let known = Set(try await client.readColumn(spreadsheetId: state.spreadsheetId,
                                                            range: "\(SheetLayout.workoutsTab)!H2:H"))
                let fresh = workoutRows.filter { !known.contains($0[7]) }
                try await client.append(spreadsheetId: state.spreadsheetId,
                                        range: "\(SheetLayout.workoutsTab)!A:H", rows: fresh)
                result.workoutsAdded = fresh.count
            }
        } catch SheetsError.spreadsheetMissing {
            // Forget the dead sheet; Home offers "Create a new sheet". Not recreated silently:
            // someone who deleted it on purpose should not find a new one appear.
            SheetsDestinationState.clear()
            throw SheetsError.spreadsheetMissing
        }
        return result
    }

    /// Makes the spreadsheet, writes the headers and the About tab in one request, and saves
    /// the new state before any data is written.
    func createSheet() async throws -> SheetsDestinationState {
        let units = await SheetUnits.preferred(from: store)
        let created = try await client.createSpreadsheet(
            title: "health4ai", tabs: [SheetLayout.dailyTab, SheetLayout.workoutsTab, SheetLayout.aboutTab])
        try await client.writeRanges(spreadsheetId: created.spreadsheetId, [
            ("\(SheetLayout.dailyTab)!A1:P1", [SheetLayout.dailyHeader(units)]),
            ("\(SheetLayout.workoutsTab)!A1:H1", [SheetLayout.workoutsHeader(units)]),
            ("\(SheetLayout.aboutTab)!A1:B\(SheetLayout.about(units).count)", SheetLayout.about(units)),
        ])
        let state = SheetsDestinationState(spreadsheetId: created.spreadsheetId,
                                           spreadsheetURL: created.spreadsheetUrl,
                                           units: units, lastWrittenDay: nil)
        state.save()
        Self.logger.info("Created health4ai sheet")
        return state
    }

    private static func dailyRange(row: Int) -> String { "\(SheetLayout.dailyTab)!A\(row):P\(row)" }

    private static func date(fromKey key: String, calendar: Calendar) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}
