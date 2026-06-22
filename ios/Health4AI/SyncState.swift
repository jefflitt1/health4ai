import Foundation
import Combine

// MARK: - Connection configuration

enum ConnectionType: String, CaseIterable {
    case supabase = "supabase" // self-hosted Supabase
    case rest     = "rest"     // any REST endpoint

    var displayName: String {
        switch self {
        case .supabase: return "Supabase"
        case .rest:     return "REST / Webhook"
        }
    }
}

enum RestAuthType: String, CaseIterable {
    case none    = "none"
    case bearer  = "bearer"
    case apiKey  = "apiKey"

    var displayName: String {
        switch self {
        case .none:   return "No Auth"
        case .bearer: return "Bearer Token"
        case .apiKey: return "API Key Header"
        }
    }
}

// MARK: - SyncState

/// Central ObservableObject driving all SwiftUI state.
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

    // MARK: - Connection configuration

    @Published var connectionType: ConnectionType {
        didSet { UserDefaults.standard.set(connectionType.rawValue, forKey: Keys.connectionType) }
    }

    /// Supabase: base project URL, e.g. https://abc123.supabase.co
    @Published var supabaseProjectURL: String {
        didSet { UserDefaults.standard.set(supabaseProjectURL, forKey: Keys.supabaseProjectURL) }
    }

    /// Generic REST: full endpoint URL
    @Published var serverURL: String {
        didSet { UserDefaults.standard.set(serverURL, forKey: Keys.serverURL) }
    }

    @Published var restAuthType: RestAuthType {
        didSet { UserDefaults.standard.set(restAuthType.rawValue, forKey: Keys.restAuthType) }
    }

    @Published var restApiKeyHeader: String {
        didSet { UserDefaults.standard.set(restApiKeyHeader, forKey: Keys.restApiKeyHeader) }
    }

    // MARK: - Auth

    @Published var isAuthenticated: Bool = false
    @Published var userEmail: String? = nil

    // MARK: - Computed endpoint

    var resolvedEndpointURL: String {
        switch connectionType {
        case .supabase:
            let base = supabaseProjectURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return base.isEmpty ? serverURL : "\(base)/functions/v1/healthkit-ingest"
        case .rest:
            return serverURL
        }
    }

    // MARK: - Lifetime record count

    @Published var lifetimeSyncedRecords: Int = 0 {
        didSet { UserDefaults.standard.set(lifetimeSyncedRecords, forKey: Keys.lifetimeSyncedRecords) }
    }

    // MARK: - Init

    init() {
        let defaults = UserDefaults.standard
        let typeRaw = defaults.string(forKey: Keys.connectionType) ?? ConnectionType.supabase.rawValue
        self.connectionType = (typeRaw == "hosted") ? .supabase : (ConnectionType(rawValue: typeRaw) ?? .supabase)
        let savedProjectURL = defaults.string(forKey: Keys.supabaseProjectURL) ?? ""
        self.supabaseProjectURL = savedProjectURL

        // Post-hosted-migration guard: hosted users never configured a supabaseProjectURL.
        // Clear the persisted type so the app presents setup flow rather than silently
        // failing to sync against an empty URL.
        if typeRaw == "hosted" && savedProjectURL.isEmpty {
            defaults.removeObject(forKey: Keys.connectionType)
        }

        self.serverURL = defaults.string(forKey: Keys.serverURL) ?? ""
        let authRaw = defaults.string(forKey: Keys.restAuthType) ?? RestAuthType.bearer.rawValue
        self.restAuthType = RestAuthType(rawValue: authRaw) ?? .bearer
        self.restApiKeyHeader = defaults.string(forKey: Keys.restApiKeyHeader) ?? "X-API-Key"
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
    static let connectionType       = "hkb.connectionType"
    static let supabaseProjectURL   = "hkb.supabaseProjectURL"
    static let serverURL            = "hkb.serverURL"
    static let restAuthType         = "hkb.restAuthType"
    static let restApiKeyHeader     = "hkb.restApiKeyHeader"
    static let lastSyncDate         = "hkb.lastSyncDate"
    static let lastSyncRecordCount  = "hkb.lastSyncRecordCount"
    static let backfillCompleted    = "hkb.backfillCompleted"
    static let backfillProgress     = "hkb.backfillProgress"
    static let lifetimeSyncedRecords = "hkb.lifetimeSyncedRecords"
}
