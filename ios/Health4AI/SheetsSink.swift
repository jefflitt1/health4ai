#if H4A_SHEETS
// Compiled only with H4A_SHEETS (off in Release by default; see docs/sheets-build-gate.md).
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
    /// `HistoryVersion.current` once a full-history sweep of both tabs has started on this
    /// sheet. nil on a sheet from builds 54-55, which `HistoryVersion.needsRebuild` rebuilds.
    var historyVersion: Int?
    /// Set when a history rebuild fails or is skipped: no new attempt before this time.
    var rebuildNotBefore: Date?

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

/// Something only the person can fix. Each kind carries its own message and action so the
/// UI never promises a fix it does not perform (Sasha, 2026-09-28).
enum SheetsAttention: Equatable {
    /// Google access removed or expired. Reconnecting keeps writing to the SAME sheet.
    case reconnectGoogle
    /// The sheet was deleted or is out of reach. The fix makes a new one.
    case sheetMissing
    /// A first sync found nothing: almost always Health read access.
    case healthAccess
    /// iOS has not been asked for every type the sheet reads. The fix shows the Health prompt.
    case healthPermission

    var message: String {
        switch self {
        case .reconnectGoogle: return "Google access was removed or expired. Reconnect Google to keep your sheet updated."
        case .sheetMissing: return "Your health4ai sheet was deleted or moved. Create a new one to keep saving your data."
        case .healthAccess: return "No health data found. In the Health app, tap your profile picture, then Apps > health4ai, and turn on the data you want saved. Then check again."
        case .healthPermission: return "Your sheet now includes Health data health4ai cannot read yet. Allow access to keep your sheet updated."
        }
    }

    var actionTitle: String {
        switch self {
        case .reconnectGoogle: return "Reconnect Google"
        case .sheetMissing: return "Create a new sheet"
        case .healthAccess: return "Check again"
        case .healthPermission: return "Allow Health access"
        }
    }

    static func from(_ error: Error) -> SheetsAttention? {
        switch error {
        case GoogleAuthError.accessRevoked, GoogleAuthError.notSignedIn: return .reconnectGoogle
        case SheetsError.spreadsheetMissing: return .sheetMissing
        case SheetsError.noHealthData: return .healthAccess
        case SheetsError.healthNotAsked: return .healthPermission
        default: return nil
        }
    }
}

final class SheetsSink: @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.jglittell.health4ai", category: "SheetsSink")
    /// Days per write on a first sync. Bounds memory for decade-long histories and saves
    /// progress between chunks, so a pass iOS cuts short resumes where it stopped.

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
    /// `allowRebuild` is true only for a foreground pass (see SheetsSyncCore.run).
    func run(now: Date = Date(), allowRebuild: Bool = false) async throws -> SheetsPassResult {
        guard GoogleTokenStore.shared.isSignedIn else { throw GoogleAuthError.notSignedIn }
        // A background pass cannot show the Health prompt, so an unasked type becomes an
        // attention state with an "Allow" action rather than HealthKit's raw error.
        let status = try await store.statusForAuthorizationRequest(toShare: [], read: DailySummaryBuilder.readTypes)
        if status == .shouldRequest { throw SheetsError.healthNotAsked }
        var state: SheetsDestinationState
        if let saved = SheetsDestinationState.load() {
            state = saved
        } else {
            state = try await createSheet()
        }

        var core = SheetsSyncCore(api: client, source: BoundHistorySource(builder: builder, units: state.units),
                                  calendar: calendar)
        let about = SheetLayout.about(state.units)
        core.rebuildExtras = [("\(SheetLayout.aboutTab)!A1:B\(about.count)", about)]
        var progress = SheetsProgress(lastWrittenDay: state.lastWrittenDay, historyVersion: state.historyVersion,
                                      rebuildNotBefore: state.rebuildNotBefore)
        Self.logger.info("pass start lastWrittenDay \(progress.lastWrittenDay ?? "nil", privacy: .private) rebuildAllowed \(allowRebuild, privacy: .public)")
        do {
            let result = try await core.run(spreadsheetId: state.spreadsheetId, progress: &progress,
                                      allowRebuild: allowRebuild, now: now) { saved in
                state.lastWrittenDay = saved.lastWrittenDay
                state.historyVersion = saved.historyVersion
                state.rebuildNotBefore = saved.rebuildNotBefore
                state.save()
                Self.logger.info("progress saved through \(saved.lastWrittenDay ?? "", privacy: .private)")
            }
            if result.rebuildSkipped {
                // Deliberately not an error or attention state (no new UI): the incremental
                // update succeeded. Logged so a stuck old history can be diagnosed.
                Self.logger.notice("history rebuild skipped: the sweep start is later than the sheet's first row")
            }
            return result
        } catch SheetsError.spreadsheetMissing {
            // Forget the dead sheet; Home offers "Create a new sheet". Not recreated silently:
            // someone who deleted it on purpose should not find a new one appear.
            SheetsDestinationState.clear()
            throw SheetsError.spreadsheetMissing
        }
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
                                           units: units, lastWrittenDay: nil, historyVersion: nil)
        state.save()
        Self.logger.info("Created health4ai sheet")
        return state
    }
}

/// The HealthKit builder with the sheet's units bound, as the sweep sees it.
private struct BoundHistorySource: SheetsHistorySource {
    let builder: DailySummaryBuilder
    let units: SheetUnits
    func earliestDataDay(now: Date) async throws -> Date { try await builder.earliestDataDay(now: now) }
    func dailyRows(from: Date, through: Date) async throws -> [[String]] {
        try await builder.dailyRows(from: from, through: through, units: units)
    }
    func workoutRows(from: Date, to: Date) async throws -> [[String]] {
        try await builder.workoutRows(from: from, to: to, units: units)
    }
}
#endif
