import Foundation

/// Rides the validator rejected for good (no samples, values out of range). Remembered so they are not
/// fetched again every import and do not use up the per-import cap. This is NOT import bookkeeping:
/// whether a ride is imported is still decided by Health. The key carries `BikeLimits.rulesVersion`,
/// so changing a rule starts a fresh set and those rides get another look.
protocol BikeRejectedStore {
    func load() -> Set<String>
    func save(_ ids: Set<String>)
}

final class MemoryRejectedStore: BikeRejectedStore {
    private var ids: Set<String> = []
    func load() -> Set<String> { ids }
    func save(_ ids: Set<String>) { self.ids = ids }
}

struct DefaultsRejectedStore: BikeRejectedStore {
    var defaults: UserDefaults = .standard
    var version = BikeLimits.rulesVersion
    var key: String { "h4a.bike.rejected.v\(version)" }
    func load() -> Set<String> { Set(defaults.stringArray(forKey: key) ?? []) }
    func save(_ ids: Set<String>) { defaults.set(ids.sorted(), forKey: key) }
}
