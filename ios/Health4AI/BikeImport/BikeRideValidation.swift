import Foundation

// Everything the Pi sends is untrusted input headed for the user's Health database. A ride that
// fails any bound is rejected whole, with a reason shown to the person, before anything is written.

enum BikeLimits {
    static let maxRidesPerImport = 200
    static let maxSamplesPerRide = 100_000
    static let maxBytes = 16 * 1024 * 1024
    static let power = 0.0...3000.0          // W
    static let cadence = 0.0...250.0         // rpm
    static let heartRate = 30.0...250.0      // bpm, or exactly 0 meaning "no reading"
    static let speed = 0.0...80.0            // mph
    static let elapsed = 1...86_400          // s, 1 s to 24 h
    static let calories = 0.0...5000.0       // kcal
    static let distance = 0.0...200.0        // mi
    static let earliestRide: Date = {
        var c = DateComponents(); c.year = 2015; c.month = 1; c.day = 1; c.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: c)!
    }()

    // The remembered-rejection set is keyed by a hash of EVERY value above, so loosening or tightening any
    // limit starts a fresh set and re-checks the rides. Add a line here when a limit is added. Nothing is
    // bumped by hand. `schema` is for a change of the rules' shape that no value above captures.
    static let schema = 1
    static var entries: [(name: String, value: String)] {
        [("maxRidesPerImport", "\(maxRidesPerImport)"), ("maxSamplesPerRide", "\(maxSamplesPerRide)"), ("maxBytes", "\(maxBytes)"),
         ("power", "\(power)"), ("cadence", "\(cadence)"), ("heartRate", "\(heartRate)"), ("speed", "\(speed)"),
         ("elapsed", "\(elapsed)"), ("calories", "\(calories)"), ("distance", "\(distance)"),
         ("earliestRide", "\(earliestRide.timeIntervalSince1970)")]
    }
    static var rulesKey: String { key(for: entries) }

    static func key(for entries: [(name: String, value: String)]) -> String {
        // FNV-1a 64: stable across launches, unlike Swift's randomly seeded hashValue.
        var h: UInt64 = 0xcbf29ce484222325
        for byte in entries.map({ "\($0.name)=\($0.value)" }).joined(separator: ";").utf8 {
            h = (h ^ UInt64(byte)) &* 0x100000001b3
        }
        return "s\(schema)-" + String(h, radix: 16)
    }
}

enum BikeRideValidator {
    /// The date rule on its own, so it can be applied from the ride id before any network call.
    /// Not remembered as a permanent rejection: a clock that was wrong can be right next time.
    static func dateProblem(start: Date, now: Date) -> String? {
        start >= BikeLimits.earliestRide && start <= now.addingTimeInterval(86_400) ? nil : "ride date is outside 2015 to tomorrow"
    }

    /// Throws `BikeImportError.invalidRide` naming the first value out of range.
    static func validate(_ ride: BikeRide, start: Date, now: Date) throws {
        func bad(_ what: String) -> BikeImportError { .invalidRide(what) }
        let s = ride.summary
        guard BikeLimits.elapsed.contains(s.elapsed) else { throw bad("length \(s.elapsed) s is outside 1 s to 24 h") }
        guard s.calories.isFinite, BikeLimits.calories.contains(s.calories) else { throw bad("calories \(s.calories) are outside 0-5000") }
        guard s.distanceMi.isFinite, BikeLimits.distance.contains(s.distanceMi) else { throw bad("distance \(s.distanceMi) mi is outside 0-200") }
        guard s.outputKJ.isFinite else { throw bad("output is not a number") }
        if let problem = dateProblem(start: start, now: now) { throw BikeImportError.invalidDate(problem) }
        guard ride.samples.count <= BikeLimits.maxSamplesPerRide else {
            throw bad("\(ride.samples.count) samples is more than the \(BikeLimits.maxSamplesPerRide) allowed")
        }
        for x in ride.samples {
            guard x.t.isFinite, x.t >= 0, x.t <= Double(s.elapsed + 1) else { throw bad("a sample time is outside the ride length") }
            guard x.power.isFinite, BikeLimits.power.contains(x.power) else { throw bad("power \(x.power) W is outside 0-3000") }
            guard x.cadence.isFinite, BikeLimits.cadence.contains(x.cadence) else { throw bad("cadence \(x.cadence) is outside 0-250") }
            guard x.speedMph.isFinite, BikeLimits.speed.contains(x.speedMph) else { throw bad("speed \(x.speedMph) mph is outside 0-80") }
            guard x.hr.isFinite, x.hr == 0 || BikeLimits.heartRate.contains(x.hr) else { throw bad("heart rate \(x.hr) is outside 30-250") }
        }
    }
}
