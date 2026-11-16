import CoreLocation
import Foundation

struct WorkoutRouteDescriptor: Codable {
    enum CodingKeys: String, CodingKey {
        case routeUUID = "route_uuid"
        case sourceCount = "source_count"
    }
    let routeUUID: String
    let sourceCount: Int
}

struct WorkoutRouteInvalidCount: Codable, Equatable {
    enum CodingKeys: String, CodingKey {
        case routeUUID = "route_uuid"
        case invalidCount = "invalid_count"
    }
    let routeUUID: String
    let invalidCount: Int
}

struct WorkoutRoutePoint: Codable, Equatable {
    enum CodingKeys: String, CodingKey {
        case routeUUID = "route_uuid"
        case pointIndex = "point_index"
        case timestamp
        case latitude
        case longitude
        case altitude
        case horizontalAccuracy = "horizontal_accuracy"
        case verticalAccuracy = "vertical_accuracy"
    }
    let routeUUID: String
    let pointIndex: Int
    let timestamp: String
    let latitude: Double
    let longitude: Double
    let altitude: Double?
    let horizontalAccuracy: Double
    let verticalAccuracy: Double

    // The route contract requires explicit null altitude for an invalid vertical fix.
    func encode(to encoder: Encoder) throws {
        var out = encoder.container(keyedBy: CodingKeys.self)
        try out.encode(routeUUID, forKey: .routeUUID)
        try out.encode(pointIndex, forKey: .pointIndex)
        try out.encode(timestamp, forKey: .timestamp)
        try out.encode(latitude, forKey: .latitude)
        try out.encode(longitude, forKey: .longitude)
        try out.encode(altitude, forKey: .altitude)
        try out.encode(horizontalAccuracy, forKey: .horizontalAccuracy)
        try out.encode(verticalAccuracy, forKey: .verticalAccuracy)
    }

    static func convert(_ location: CLLocation, route: UUID, index: Int) -> WorkoutRoutePoint? {
        guard CLLocationCoordinate2DIsValid(location.coordinate),
              location.coordinate.latitude.isFinite, location.coordinate.longitude.isFinite,
              location.timestamp.timeIntervalSince1970.isFinite,
              location.horizontalAccuracy.isFinite, location.horizontalAccuracy >= 0,
              location.verticalAccuracy.isFinite else { return nil }
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timestamp = format.string(from: location.timestamp)
        guard timestamp.count >= 20, timestamp.count <= 24 else { return nil }
        return WorkoutRoutePoint(routeUUID: route.uuidString.lowercased(), pointIndex: index, timestamp: timestamp,
            latitude: location.coordinate.latitude, longitude: location.coordinate.longitude,
            altitude: location.verticalAccuracy < 0 || !location.altitude.isFinite ? nil : location.altitude,
            horizontalAccuracy: location.horizontalAccuracy, verticalAccuracy: location.verticalAccuracy)
    }
}

struct WorkoutRouteObservation {
    let points: [WorkoutRoutePoint]
    let invalidCount: Int
}

struct WorkoutRouteSummary: Equatable {
    let valid: Int
    let invalid: Int
    var source: Int { valid + invalid }
}

/// Bounded collector for HealthKit's unspecified callback batch sizes. Retains at
/// most the declared route size, with original indexes and explicit invalid counts.
final class WorkoutRouteCollector {
    let routeID: UUID
    let expected: Int
    private(set) var received = 0
    private var points: [WorkoutRoutePoint] = []
    private var invalidCount = 0

    init(routeID: UUID, expected: Int) { self.routeID = routeID; self.expected = expected }

    func append(_ locations: [CLLocation], done: Bool) throws -> WorkoutRouteObservation? {
        guard expected >= 0, expected <= 100_000, locations.count <= expected - received else {
            throw WorkoutDetailError.limit
        }
        for location in locations {
            if let point = WorkoutRoutePoint.convert(location, route: routeID, index: received) { points.append(point) }
            else { invalidCount += 1 }
            received += 1
        }
        guard done else { return nil }
        guard received == expected else { throw WorkoutDetailError.healthChanged }
        return WorkoutRouteObservation(points: points, invalidCount: invalidCount)
    }
}
