import Foundation

/// Rides the validator rejected on their CONTENT (no samples, values out of range), remembered as
/// `id -> fingerprint of the listing summary`. A ride is skipped without a fetch only while the bike's
/// listing still shows the same fingerprint; if the summary changes (a corrected or finished ride) it is
/// fetched again. This is NOT import bookkeeping: whether a ride is imported is still decided by Health.
/// The storage key is derived from every `BikeLimits` value, so changing any limit starts a fresh set.
protocol BikeRejectedStore {
    func load() -> [String: String]
    func save(_ rejected: [String: String])
}

enum BikeFingerprint {
    /// Built from every field the listing summary carries.
    static func of(_ s: BikeRideSummary) -> String { "\(s.elapsed)|\(s.outputKJ)|\(s.calories)|\(s.distanceMi)" }
}

final class MemoryRejectedStore: BikeRejectedStore {
    private var rejected: [String: String] = [:]
    func load() -> [String: String] { rejected }
    func save(_ rejected: [String: String]) { self.rejected = rejected }
}

struct DefaultsRejectedStore: BikeRejectedStore {
    var defaults: UserDefaults = .standard
    var rulesKey = BikeLimits.rulesKey
    var key: String { "h4a.bike.rejected.\(rulesKey)" }
    func load() -> [String: String] { defaults.dictionary(forKey: key) as? [String: String] ?? [:] }
    func save(_ rejected: [String: String]) { defaults.set(rejected, forKey: key) }
}
