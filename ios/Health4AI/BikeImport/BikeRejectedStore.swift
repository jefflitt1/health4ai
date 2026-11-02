import Foundation

/// Rides the validator rejected on their CONTENT (no samples, values out of range), remembered as
/// `id -> BikeRejection`: the fingerprint of the listing summary and the day it was rejected. A ride is
/// skipped without a fetch only while the listing still shows the same fingerprint AND the rejection is
/// younger than `BikeLimits.rejectionExpiry`; a changed summary (a corrected or finished ride) or an old
/// entry means fetch again. This is NOT import bookkeeping: whether a ride is imported is still decided by Health.
/// The storage key is derived from every `BikeLimits` value, so changing any limit starts a fresh set.
protocol BikeRejectedStore {
    func load() -> [String: BikeRejection]
    func save(_ rejected: [String: BikeRejection])
}

struct BikeRejection: Equatable {
    var fingerprint: String
    /// When it was rejected. Nil for an entry written before dates were kept: that counts as expired.
    var at: Date?

    /// Still trusted: same listing, and rejected less than `BikeLimits.rejectionExpiry` ago. An entry with
    /// no date, or dated in the future (the clock was wrong), is not trusted.
    func holds(for fingerprint: String, now: Date) -> Bool {
        guard self.fingerprint == fingerprint, let at else { return false }
        let age = now.timeIntervalSince(at)
        return age >= 0 && age < BikeLimits.rejectionExpiry
    }
}

enum BikeFingerprint {
    /// Built from every field the listing summary carries.
    static func of(_ s: BikeRideSummary) -> String { "\(s.elapsed)|\(s.outputKJ)|\(s.calories)|\(s.distanceMi)" }
}

final class MemoryRejectedStore: BikeRejectedStore {
    private var rejected: [String: BikeRejection] = [:]
    func load() -> [String: BikeRejection] { rejected }
    func save(_ rejected: [String: BikeRejection]) { self.rejected = rejected }
}

/// Stored as `id -> ["f": fingerprint, "t": seconds since 1970]`. The earlier form, `id -> fingerprint`
/// (a bare string), is still read and counts as expired, so those rides are checked once more.
struct DefaultsRejectedStore: BikeRejectedStore {
    var defaults: UserDefaults = .standard
    var rulesKey = BikeLimits.rulesKey
    var key: String { "h4a.bike.rejected.\(rulesKey)" }

    func load() -> [String: BikeRejection] {
        var out: [String: BikeRejection] = [:]
        for (id, raw) in defaults.dictionary(forKey: key) ?? [:] {
            if let legacy = raw as? String {
                out[id] = BikeRejection(fingerprint: legacy, at: nil)
            } else if let d = raw as? [String: Any], let f = d["f"] as? String {
                out[id] = BikeRejection(fingerprint: f, at: (d["t"] as? Double).map { Date(timeIntervalSince1970: $0) })
            }
        }
        return out
    }

    func save(_ rejected: [String: BikeRejection]) {
        defaults.set(rejected.mapValues { r -> [String: Any] in
            var d: [String: Any] = ["f": r.fingerprint]
            if let at = r.at { d["t"] = at.timeIntervalSince1970 }
            return d
        }, forKey: key)
    }
}
