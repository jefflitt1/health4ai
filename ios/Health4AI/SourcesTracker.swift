import Foundation
import HealthKit

// MARK: - HealthSourceInfo

struct HealthSourceInfo: Codable, Equatable {
    var sampleCount: Int
    var lastSeen: Date
}

// MARK: - SourcesTracker

/// Persisted registry of every device/app that has contributed HealthKit samples, keyed by the
/// HKSource's own name (e.g. "Oura", "Apple Watch", "MyFitnessPal") — never the synthetic
/// "HealthKit (all sources)" label the app posts for merged hourly totals (see
/// `HealthKitManager.allSourcesLabel`).
///
/// Callers must always pass the RAW `HKSample`s HealthKit returned, before any merged-hours
/// conversion: `hourlyTotals(for:touchedBy:notBefore:)` only ever sees `HealthKitManager
/// .allSourcesLabel` on its synthetic output, and the real per-device names exist only on the
/// samples it was given. `syncTypeLocked` and `backfillType` both call `record` on that
/// pre-conversion array for this reason.
final class SourcesTracker: @unchecked Sendable {
    static let shared = SourcesTracker()

    private let lock = NSLock()
    private var sources: [String: HealthSourceInfo]
    private let fileURL: URL

    private init() {
        let dir = SyncHistoryStore.applicationSupportDirectory()
        self.fileURL = dir.appendingPathComponent("sources.json")
        self.sources = Self.load(from: fileURL)
    }

    private static func load(from url: URL) -> [String: HealthSourceInfo] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([String: HealthSourceInfo].self, from: data)) ?? [:]
    }

    /// Called only while `lock` is held.
    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(sources) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Records every RAW sample's contributing source. A no-op for an empty array, so calling
    /// this on every sync page (including ones with nothing new) costs nothing.
    func record(samples: [HKSample]) {
        guard !samples.isEmpty else { return }
        let now = Date()
        lock.lock()
        defer { lock.unlock() }
        for sample in samples {
            let name = sample.sourceRevision.source.name
            guard name != HealthKitManager.allSourcesLabel, !name.isEmpty else { continue }
            var info = sources[name] ?? HealthSourceInfo(sampleCount: 0, lastSeen: now)
            info.sampleCount += 1
            if now > info.lastSeen { info.lastSeen = now }
            sources[name] = info
        }
        save()
    }

    /// A snapshot, most-recently-seen first.
    func all() -> [(name: String, info: HealthSourceInfo)] {
        lock.lock()
        defer { lock.unlock() }
        return sources.map { (name: $0.key, info: $0.value) }
            .sorted { $0.info.lastSeen > $1.info.lastSeen }
    }

    #if DEBUG
    /// Screenshot fixture only. Same DEBUG/launch-argument gating as
    /// `SyncHistoryStore.seedForScreenshotsIfNeeded`.
    func seedForScreenshotsIfNeeded() {
        guard ProcessInfo.processInfo.arguments.contains("-h4aiScreenshotSources") else { return }
        let now = Date()
        lock.lock()
        defer { lock.unlock() }
        sources = [
            "Apple Watch":   HealthSourceInfo(sampleCount: 48_213, lastSeen: now),
            "iPhone":        HealthSourceInfo(sampleCount: 12_045, lastSeen: now.addingTimeInterval(-600)),
            "Oura":          HealthSourceInfo(sampleCount: 3_320, lastSeen: now.addingTimeInterval(-3_600)),
            "MyFitnessPal":  HealthSourceInfo(sampleCount: 812, lastSeen: now.addingTimeInterval(-86_400)),
        ]
        save()
    }
    #endif
}
