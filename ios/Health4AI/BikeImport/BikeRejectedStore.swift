import Foundation
import os

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

/// Stored as `id -> ["f": fingerprint, "t": seconds since 1970]` under a key derived from the rules.
/// The earlier form, `id -> fingerprint` (a bare string), is read only under the SAME key and counts as
/// expired, so those rides are checked once more; a changed rules key starts a fresh set and `save`
/// deletes the sets of other keys.
///
/// Corrupt data is never silently dropped or trusted: each case is reported through `onProblem` (logged by
/// default, with the ride id where there is one), and the affected ride simply has no usable entry, so
/// it is fetched and judged again.
struct DefaultsRejectedStore: BikeRejectedStore {
    private static let logger = Logger(subsystem: "com.jglittell.health4ai", category: "BikeRejectedStore")
    static let keyPrefix = "h4a.bike.rejected."

    var defaults: UserDefaults = .standard
    var rulesKey = BikeLimits.rulesKey
    var onProblem: (String) -> Void = { logger.error("\($0, privacy: .public)") }
    var key: String { Self.keyPrefix + rulesKey }

    func load() -> [String: BikeRejection] {
        guard let stored = defaults.object(forKey: key) else { return [:] }
        guard let entries = stored as? [String: Any] else {
            onProblem("remembered rejections under \(key) are not a dictionary; all rides will be checked again")
            return [:]
        }
        var out: [String: BikeRejection] = [:]
        for (id, raw) in entries {
            if let legacy = raw as? String {
                out[id] = BikeRejection(fingerprint: legacy, at: nil)
            } else if let d = raw as? [String: Any], let f = d["f"] as? String {
                var at: Date?
                if let t = d["t"] {
                    if let seconds = t as? Double { at = Date(timeIntervalSince1970: seconds) } else {
                        onProblem("remembered rejection for ride \(id) has a date that is not a number; it will be checked again")
                    }
                }
                out[id] = BikeRejection(fingerprint: f, at: at)
            } else {
                onProblem("remembered rejection for ride \(id) has an unknown shape; it will be checked again")
            }
        }
        return out
    }

    func save(_ rejected: [String: BikeRejection]) {
        // Sets stored under earlier rules keys can never be read again: remove them.
        for other in defaults.dictionaryRepresentation().keys where other.hasPrefix(Self.keyPrefix) && other != key {
            defaults.removeObject(forKey: other)
        }
        defaults.set(rejected.mapValues { r -> [String: Any] in
            var d: [String: Any] = ["f": r.fingerprint]
            if let at = r.at { d["t"] = at.timeIntervalSince1970 }
            return d
        }, forKey: key)
    }
}
