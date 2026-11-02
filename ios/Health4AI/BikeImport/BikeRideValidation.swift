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
}

enum BikeRideValidator {
    /// Throws `BikeImportError.invalidRide` naming the first value out of range.
    static func validate(_ ride: BikeRide, start: Date, now: Date) throws {
        func bad(_ what: String) -> BikeImportError { .invalidRide(what) }
        let s = ride.summary
        guard BikeLimits.elapsed.contains(s.elapsed) else { throw bad("length \(s.elapsed) s is outside 1 s to 24 h") }
        guard s.calories.isFinite, BikeLimits.calories.contains(s.calories) else { throw bad("calories \(s.calories) are outside 0-5000") }
        guard s.distanceMi.isFinite, BikeLimits.distance.contains(s.distanceMi) else { throw bad("distance \(s.distanceMi) mi is outside 0-200") }
        guard s.outputKJ.isFinite else { throw bad("output is not a number") }
        guard start >= BikeLimits.earliestRide, start <= now.addingTimeInterval(86_400) else {
            throw bad("ride date is outside 2015 to tomorrow")
        }
        guard ride.samples.count <= BikeLimits.maxSamplesPerRide else {
            throw bad("\(ride.samples.count) samples is more than the \(BikeLimits.maxSamplesPerRide) allowed")
        }
        for x in ride.samples {
            guard x.t >= 0, x.t <= s.elapsed + 1 else { throw bad("a sample at \(x.t) s is past the ride length") }
            guard x.power.isFinite, BikeLimits.power.contains(x.power) else { throw bad("power \(x.power) W is outside 0-3000") }
            guard x.cadence.isFinite, BikeLimits.cadence.contains(x.cadence) else { throw bad("cadence \(x.cadence) is outside 0-250") }
            guard x.speedMph.isFinite, BikeLimits.speed.contains(x.speedMph) else { throw bad("speed \(x.speedMph) mph is outside 0-80") }
            guard x.hr.isFinite, x.hr == 0 || BikeLimits.heartRate.contains(x.hr) else { throw bad("heart rate \(x.hr) is outside 30-250") }
        }
    }
}
