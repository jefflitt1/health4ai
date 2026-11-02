import Foundation

// Models for the Peloton Pi ride API (~/peloton-pi/peloton_pi/server.py, ride.py):
//   GET /api/rides      -> {"rides": [summary...], "records": {...}}
//   GET /api/rides/{id} -> {"summary": summary, "samples": [[t, cadence, power, resistance|null, speed_mph, hr], ...]}
// Parsing is strict about the fields the import needs and ignores the rest, so a Pi that adds
// fields keeps working while a response that is not from a Pi fails loudly.

struct BikeRideSummary: Decodable, Equatable {
    let id: String
    let elapsed: Int
    let outputKJ: Double
    let calories: Double
    let distanceMi: Double

    enum CodingKeys: String, CodingKey {
        case id, elapsed, calories
        case outputKJ = "output_kj"
        case distanceMi = "distance_mi"
    }
}

/// One ~1 Hz reading: [elapsed_s, cadence_rpm, power_w, resistance_pct|null, speed_mph, hr_bpm].
struct BikeRideSample: Decodable, Equatable {
    let t: Int
    let cadence: Double
    let power: Double
    let resistance: Double?
    let speedMph: Double
    let hr: Double

    init(t: Int, cadence: Double, power: Double, resistance: Double? = nil, speedMph: Double, hr: Double) {
        self.t = t; self.cadence = cadence; self.power = power
        self.resistance = resistance; self.speedMph = speedMph; self.hr = hr
    }

    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        t = Int(try c.decode(Double.self))
        cadence = try c.decode(Double.self)
        power = try c.decode(Double.self)
        resistance = try c.decodeNil() ? nil : try c.decode(Double.self)
        speedMph = try c.decode(Double.self)
        hr = try c.decode(Double.self)
    }
}

struct BikeRide: Decodable, Equatable {
    let summary: BikeRideSummary
    let samples: [BikeRideSample]
}

struct BikeRideList: Decodable {
    let rides: [BikeRideSummary]
}

enum BikeRideID {
    /// `20261102T172230Z` -> 2026-11-02 17:22:30 UTC. Strict: nil for anything else, including
    /// impossible dates (month 13, day 31 in a 30-day month), so the id is safe to put in a URL path.
    static func startDate(from id: String) -> Date? {
        guard id.count == 16, id.utf8.allSatisfy({ $0 < 128 }) else { return nil }
        let chars = Array(id)
        guard chars[8] == "T", chars[15] == "Z",
              (chars[0..<8] + chars[9..<15]).allSatisfy({ $0.isNumber }) else { return nil }
        func num(_ r: Range<Int>) -> Int { Int(String(chars[r]))! }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let comps = DateComponents(year: num(0..<4), month: num(4..<6), day: num(6..<8),
                                   hour: num(9..<11), minute: num(11..<13), second: num(13..<15))
        guard let date = cal.date(from: comps) else { return nil }
        // Round-trip: Calendar silently normalises 31 Nov to 1 Dec; reject that.
        let back = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return back == comps ? date : nil
    }

    /// Stable de-duplication key written to HKMetadataKeySyncIdentifier. It names the source and the
    /// ride, not the host, so a Pi reached by IP one day and by .local the next is the same ride.
    static func syncIdentifier(for id: String) -> String { "com.health4ai.pelotonpi:\(id)" }
    static let syncVersion = 1
}
