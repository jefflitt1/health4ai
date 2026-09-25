import Foundation

// MARK: - SyncTrigger

/// What started one sync or import run. Distinguishing `backgroundDelivery` from the rest is
/// the whole point of this file: it is the only on-screen proof that HKObserverQuery +
/// background delivery actually work while the app is closed (register D335).
enum SyncTrigger: String, Codable, CaseIterable {
    case launch
    case foreground
    case backgroundDelivery
    case backgroundTask
    case manual
    case importHistory

    var displayName: String {
        switch self {
        case .launch:             return "App launch"
        case .foreground:         return "Foreground"
        case .backgroundDelivery: return "Background delivery"
        case .backgroundTask:     return "Background refresh"
        case .manual:             return "Sync Now"
        case .importHistory:     return "History import"
        }
    }

    var systemImage: String {
        switch self {
        case .launch:             return "power"
        case .foreground:         return "iphone"
        case .backgroundDelivery: return "antenna.radiowaves.left.and.right"
        case .backgroundTask:     return "clock.arrow.circlepath"
        case .manual:             return "hand.tap"
        case .importHistory:     return "tray.and.arrow.down"
        }
    }
}

// MARK: - SyncHistoryEntry

/// One recorded sync or import run.
///
/// `counts` is keyed by a human-readable metric name, not an HK identifier string, and only
/// includes types that actually sent something this run — a routine incremental sync touches
/// at most a handful of the ~120 possible types, and listing zeroes for the rest would make
/// every row unreadable.
struct SyncHistoryEntry: Codable, Identifiable, Equatable {
    let id: UUID
    let date: Date
    let trigger: SyncTrigger
    let counts: [String: Int]
    let success: Bool
    let errorText: String?

    init(id: UUID = UUID(), date: Date = Date(), trigger: SyncTrigger,
         counts: [String: Int], success: Bool, errorText: String? = nil) {
        self.id = id
        self.date = date
        self.trigger = trigger
        self.counts = counts
        self.success = success
        self.errorText = errorText
    }

    var totalCount: Int { counts.values.reduce(0, +) }
}

// MARK: - SyncHistoryStore

/// Persisted, bounded log of sync runs, most-recent-first.
///
/// A lock-guarded class, not an actor or a `@MainActor` type like `SyncState`. Callers span
/// the HKObserverQuery callback queue, `SyncEngine`'s serialized-but-not-MainActor sync tasks,
/// and the BGTask expiration/completion handlers — none of those call sites can `await` a
/// cross-actor hop just to append one row. Same pattern as `BGTaskCompletion` above: the
/// append-and-persist happens synchronously under an `NSLock`.
final class SyncHistoryStore: @unchecked Sendable {
    static let shared = SyncHistoryStore()

    /// Last 50 entries only, per spec. Anything older is dropped, not archived: this is a
    /// diagnostic tail, not an audit log.
    static let cap = 50

    private let lock = NSLock()
    private var entries: [SyncHistoryEntry]
    private let fileURL: URL

    private init() {
        let dir = Self.applicationSupportDirectory()
        self.fileURL = dir.appendingPathComponent("sync-history.json")
        self.entries = Self.load(from: fileURL)
    }

    static func applicationSupportDirectory() -> URL {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                 appropriateFor: nil, create: true)) ?? fm.temporaryDirectory
        let dir = base.appendingPathComponent("health4ai", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func load(from url: URL) -> [SyncHistoryEntry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([SyncHistoryEntry].self, from: data)) ?? []
    }

    /// Called only while `lock` is held.
    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Appends one run, most-recent-first, trimmed to `cap`. Safe from any thread.
    func record(_ entry: SyncHistoryEntry) {
        lock.lock()
        defer { lock.unlock() }
        entries.insert(entry, at: 0)
        if entries.count > Self.cap {
            entries.removeLast(entries.count - Self.cap)
        }
        save()
    }

    /// A snapshot of the log, most-recent-first.
    func all() -> [SyncHistoryEntry] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }

    var mostRecent: SyncHistoryEntry? {
        lock.lock()
        defer { lock.unlock() }
        return entries.first
    }

    #if DEBUG
    /// Screenshot fixture only. Launch-argument gated and DEBUG-only, matching the pattern in
    /// `SyncState.init` — Xcode Cloud archives Release, which never compiles this.
    func seedForScreenshotsIfNeeded() {
        guard ProcessInfo.processInfo.arguments.contains("-h4aiScreenshotSyncHistory") else { return }
        let now = Date()
        lock.lock()
        defer { lock.unlock() }
        entries = [
            SyncHistoryEntry(date: now.addingTimeInterval(-120), trigger: .backgroundDelivery,
                              counts: ["Steps": 42, "Heart Rate": 18, "Active Energy": 6], success: true),
            SyncHistoryEntry(date: now.addingTimeInterval(-3_600), trigger: .foreground,
                              counts: ["Sleep Analysis": 6], success: true),
            SyncHistoryEntry(date: now.addingTimeInterval(-7_300), trigger: .manual,
                              counts: [:], success: true),
            SyncHistoryEntry(date: now.addingTimeInterval(-30_000), trigger: .backgroundDelivery,
                              counts: ["Steps": 210], success: true),
            SyncHistoryEntry(date: now.addingTimeInterval(-90_000), trigger: .backgroundTask,
                              counts: [:], success: false,
                              errorText: "Sync failed for all 4 data types. The request timed out."),
            SyncHistoryEntry(date: now.addingTimeInterval(-190_000), trigger: .importHistory,
                              counts: ["History import": 48_213], success: true),
        ]
        save()
    }
    #endif
}
