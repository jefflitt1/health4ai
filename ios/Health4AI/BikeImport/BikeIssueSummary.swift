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
        let names = known.map(format)
        rides = Array(names.prefix(Self.maxNamed))
        more = max(names.count - Self.maxNamed, 0)
        self.unreadable = unreadable
        // Compared with the rides that have the headline reason (the ones the detail line is about), not the whole row.
        allUnreadable = unreadable == ordered[0].value
    }

    /// Rides with the headline reason whose id has no readable date: counted once, never listed one by one.
    let unreadable: Int
    /// Every ride with the headline reason is unreadable: the reason already says so, so there is no detail line.
    let allUnreadable: Bool

    var unreadablePhrase: String? {
        unreadable == 0 ? nil : unreadable == 1 ? "1 ride with an unreadable date" : "\(unreadable) rides with unreadable dates"
    }

    /// The caption under the reason: named dated rides, "and N more", then the unreadable count last.
    /// Prefixed "For this reason:" only when the row also has other reasons. Nil when there is nothing to name.
    var detail: String? {
        if allUnreadable { return nil }
        var text = rides.joined(separator: ", ")
        if more > 0 { text += ", and \(more) more" }
        if let phrase = unreadablePhrase { text += (text.isEmpty ? "" : ", plus ") + phrase }
        if text.isEmpty { return nil }
        return otherReasons > 0 ? "For this reason: \(text)" : text
    }

    /// Issues with no ride attached, shown as plain lines.
    static func runLevel(_ issues: [BikeIssue]) -> [String] {
        issues.filter { $0.rideID == nil }.map(\.reason)
    }
}
