import Foundation
import Combine

// MARK: - SyncState

/// Central ObservableObject driving all SwiftUI state for the settings screen.
@MainActor
final class SyncState: ObservableObject {

    // MARK: - Sync status

    @Published var lastSyncDate: Date? {
        didSet { UserDefaults.standard.set(lastSyncDate, forKey: Keys.lastSyncDate) }
    }

    @Published var lastSyncRecordCount: Int = 0 {
        didSet { UserDefaults.standard.set(lastSyncRecordCount, forKey: Keys.lastSyncRecordCount) }
    }

    @Published var nextScheduledSync: Date? = nil
    @Published var isSyncing: Bool = false
    @Published var syncError: String? = nil

    // MARK: - Backfill status

    @Published var isBackfilling: Bool = false
    @Published var backfillTotalRecords: Int = 0
    @Published var backfillSyncedRecords: Int = 0
    @Published var backfillCompleted: Bool = false {
        didSet { UserDefaults.standard.set(backfillCompleted, forKey: Keys.backfillCompleted) }
    }
    @Published var backfillError: String? = nil
    @Published var backfillEarliestDate: Date? = nil
    @Published var backfillLatestDate: Date? = nil

    // MARK: - Configuration

    @Published var serverURL: String {
        didSet { UserDefaults.standard.set(serverURL, forKey: Keys.serverURL) }
    }

    // MARK: - Auth

    @Published var isAuthenticated: Bool = false
    @Published var userEmail: String? = nil

    // MARK: - Lifetime record count

    @Published var lifetimeSyncedRecords: Int = 0 {
        didSet { UserDefaults.standard.set(lifetimeSyncedRecords, forKey: Keys.lifetimeSyncedRecords) }
    }

    // MARK: - Init

    init() {
        let defaults = UserDefaults.standard
        self.serverURL = defaults.string(forKey: Keys.serverURL)
            ?? "https://donnmhbwhpjlmpnwgdqr.supabase.co/functions/v1/healthkit-ingest"
        self.lastSyncDate = defaults.object(forKey: Keys.lastSyncDate) as? Date
        self.lastSyncRecordCount = defaults.integer(forKey: Keys.lastSyncRecordCount)
        self.backfillCompleted = defaults.bool(forKey: Keys.backfillCompleted)
        self.lifetimeSyncedRecords = defaults.integer(forKey: Keys.lifetimeSyncedRecords)
        self.backfillSyncedRecords = defaults.integer(forKey: Keys.backfillProgress)
    }

    // MARK: - Mutators (called from background threads via MainActor dispatch)

    func recordSyncComplete(count: Int) {
        lastSyncDate = Date()
        lastSyncRecordCount = count
        lifetimeSyncedRecords += count
        isSyncing = false
        syncError = nil
    }

    func recordSyncError(_ message: String) {
        isSyncing = false
        syncError = message
    }

    func recordBackfillProgress(synced: Int, total: Int, earliest: Date?, latest: Date?) {
        backfillSyncedRecords = synced
        backfillTotalRecords = total
        if let e = earliest { backfillEarliestDate = e }
        if let l = latest   { backfillLatestDate = l }
        lifetimeSyncedRecords += synced
        UserDefaults.standard.set(backfillSyncedRecords, forKey: Keys.backfillProgress)
    }

    func recordBackfillComplete() {
        isBackfilling = false
        backfillCompleted = true
        backfillError = nil
    }

    func recordBackfillError(_ message: String) {
        isBackfilling = false
        backfillError = message
    }

    // MARK: - Computed helpers

    var backfillProgressFraction: Double {
        guard backfillTotalRecords > 0 else { return 0 }
        return Double(backfillSyncedRecords) / Double(backfillTotalRecords)
    }

    var formattedLastSync: String {
        guard let date = lastSyncDate else { return "Never" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    var formattedNextSync: String {
        guard let date = nextScheduledSync else { return "Not scheduled" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - UserDefaults Keys

private enum Keys {
    static let serverURL          = "hkb.serverURL"
    static let lastSyncDate       = "hkb.lastSyncDate"
    static let lastSyncRecordCount = "hkb.lastSyncRecordCount"
    static let backfillCompleted  = "hkb.backfillCompleted"
    static let backfillProgress   = "hkb.backfillProgress"
    static let lifetimeSyncedRecords = "hkb.lifetimeSyncedRecords"
}
