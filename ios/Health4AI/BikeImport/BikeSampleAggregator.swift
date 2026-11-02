import Foundation

// Turns ~1 Hz bike samples into the few-seconds buckets that become HealthKit samples.
//
// Why 5 s: a 60 min ride is 3,600 readings; written raw that is ~18,000 HealthKit samples across
// power, cadence, energy, distance and HR for one workout. 5 s buckets give 720 per type, keep
// every interval and surge visible in Health's chart, and preserve the average (bucket means).

struct BikeBucket: Equatable {
    /// Seconds from ride start, [startOffset, endOffset).
    let startOffset: Int
    let endOffset: Int
    let cadence: Double
    let power: Double
    /// Mean of non-zero HR readings only; nil if the strap reported nothing in this bucket.
    let heartRate: Double?
    /// Sum of watts and of mph in the bucket: weights for sharing out the ride's energy and distance.
    let workWeight: Double
    let distanceWeight: Double
}

enum BikeSampleAggregator {
    static let bucketSeconds = 5

    /// The ride length is summary.elapsed and is the hard end: no bucket ends after it, and samples at
    /// or past it fold into the final bucket. If samples stop early, the buckets simply stop early.
    static func buckets(samples: [BikeRideSample], elapsed: Int, bucketSeconds: Int = bucketSeconds) -> [BikeBucket] {
        guard !samples.isEmpty, bucketSeconds > 0 else { return [] }
        let duration = max(elapsed, 1)
        let lastIndex = (duration - 1) / bucketSeconds
        var groups: [Int: [BikeRideSample]] = [:]
        for s in samples where s.t >= 0 {
            // A sample at exactly `duration` has no interval of its own; fold it into the final bucket.
            groups[min(s.t / bucketSeconds, lastIndex), default: []].append(s)
        }
        return groups.keys.sorted().map { index in
            let g = groups[index]!
            let n = Double(g.count)
            let hrs = g.map(\.hr).filter { $0 > 0 }
            return BikeBucket(
                startOffset: index * bucketSeconds,
                endOffset: min(index * bucketSeconds + bucketSeconds, duration),
                cadence: g.map(\.cadence).reduce(0, +) / n,
                power: g.map(\.power).reduce(0, +) / n,
                heartRate: hrs.isEmpty ? nil : hrs.reduce(0, +) / Double(hrs.count),
                workWeight: g.map(\.power).reduce(0, +),
                distanceWeight: g.map(\.speedMph).reduce(0, +))
        }
    }

    /// Splits `total` across buckets in proportion to `weight`, falling back to bucket length when
    /// every weight is zero. The parts sum to `total` (the Pi's own summary), so the workout's
    /// energy and distance match what the bike showed instead of a re-derived estimate.
    static func allocate(total: Double, over buckets: [BikeBucket], weight: (BikeBucket) -> Double) -> [Double] {
        guard total > 0, !buckets.isEmpty else { return Array(repeating: 0, count: buckets.count) }
        var weights = buckets.map(weight)
        if weights.reduce(0, +) <= 0 { weights = buckets.map { Double($0.endOffset - $0.startOffset) } }
        let sum = weights.reduce(0, +)
        guard sum > 0 else { return Array(repeating: 0, count: buckets.count) }
        return weights.map { total * $0 / sum }
    }
}
