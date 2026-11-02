import Foundation

/// One screen row per kind of issue, for issues that belong to a ride: how many rides, the reason most of
/// them share, and at most three of THOSE rides named by date (never by raw id), then "and N more".
/// Run-level issues (`rideID == nil`, such as "older rides were left for the next import") are not rides
/// and are never counted or named here; the view shows them as plain captions.
struct BikeIssueSummary: Equatable {
    static let maxNamed = 3
    /// Rides in this kind.
    let count: Int
    /// The most common reason, and how many rides share it.
    let reason: String
    let reasonCount: Int
    /// Number of other distinct reasons in this kind.
    let otherReasons: Int
    /// Dates of rides with the headline `reason` only, never those with another reason.
    let rides: [String]
    let more: Int

    init?(_ issues: [BikeIssue], format: (Date) -> String) {
        let rideIssues = issues.filter { $0.rideID != nil }
        guard !rideIssues.isEmpty else { return nil }
        count = rideIssues.count
        let tally = Dictionary(grouping: rideIssues, by: \.reason).mapValues(\.count)
        let ordered = tally.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
        reason = ordered[0].key
        reasonCount = ordered[0].value
        otherReasons = ordered.count - 1
        let dates = rideIssues.filter { $0.reason == ordered[0].key }.compactMap { $0.rideID }.map { BikeRideID.startDate(from: $0) }
        // Readable dates in time order first; a ride with an unreadable id goes last.
        let known = dates.compactMap { $0 }.sorted()
        let unreadable = dates.count - known.count
        let names = known.map(format) + Array(repeating: "a ride with an unreadable date", count: unreadable)
        rides = Array(names.prefix(Self.maxNamed))
        more = max(names.count - Self.maxNamed, 0)
    }

    /// Issues with no ride attached, shown as plain lines.
    static func runLevel(_ issues: [BikeIssue]) -> [String] {
        issues.filter { $0.rideID == nil }.map(\.reason)
    }
}
