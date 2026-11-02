import Foundation

/// One screen row per kind of issue: how many, the reason most of them share, and at most three rides
/// named by date (never by raw id), then "and N more".
struct BikeIssueSummary: Equatable {
    static let maxNamed = 3
    let count: Int
    let reason: String
    let otherReasons: Int
    let rides: [String]
    let more: Int

    init?(_ issues: [BikeIssue], format: (Date) -> String) {
        guard !issues.isEmpty else { return nil }
        count = issues.count
        let tally = Dictionary(grouping: issues, by: \.reason).mapValues(\.count)
        let ordered = tally.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
        reason = ordered[0].key
        otherReasons = ordered.count - 1
        let dates = issues.compactMap { $0.rideID }.map { BikeRideID.startDate(from: $0) }
        let named = dates.sorted { ($0 ?? .distantPast) < ($1 ?? .distantPast) }
        rides = named.prefix(Self.maxNamed).map { $0.map(format) ?? "a ride with an unreadable date" }
        more = max(named.count - Self.maxNamed, 0)
    }
}
