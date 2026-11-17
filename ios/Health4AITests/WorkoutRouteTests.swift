import XCTest
import CoreLocation
@testable import Health4AI

@MainActor
final class WorkoutRouteTests: XCTestCase {
    private let route = UUID()
    private func location(latitude: Double = 40, horizontal: Double = 3,
                          vertical: Double = 4, altitude: Double = 10) -> CLLocation {
        CLLocation(coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: -70), altitude: altitude,
            horizontalAccuracy: horizontal, verticalAccuracy: vertical,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000))
    }

    func testAllBatchesRequiredAndInvalidPointsKeepOriginalIndexGaps() throws {
        let collector = WorkoutRouteCollector(routeID: route, expected: 3)
        XCTAssertNil(try collector.append([location(), location(latitude: 200)], done: false))
        let final = try XCTUnwrap(collector.append([location()], done: true))
        XCTAssertEqual(final.points.map(\.pointIndex), [0, 2])
        XCTAssertEqual(final.invalidCount, 1)
        XCTAssertEqual(final.points[0].routeUUID, route.uuidString.lowercased())
    }

    func testTruncatedDoneAndOverflowFailRatherThanClaimComplete() {
        XCTAssertThrowsError(try WorkoutRouteCollector(routeID: route, expected: 2).append([location()], done: true))
        XCTAssertThrowsError(try WorkoutRouteCollector(routeID: route, expected: 1).append([location(), location()], done: false))
        XCTAssertThrowsError(try WorkoutRouteCollector(routeID: route, expected: 100_001).append([], done: true))
    }

    func testInvalidVerticalFixUsesExplicitNullAltitude() throws {
        let point = try XCTUnwrap(WorkoutRoutePoint.convert(location(vertical: -1, altitude: .nan), route: route, index: 0))
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(point)) as! [String: Any]
        XCTAssertTrue(object["altitude"] is NSNull)
        XCTAssertEqual(object["vertical_accuracy"] as? Double, -1)
    }

    func testInvalidCoordinatesAndAccuracyAreOmitted() {
        for invalid in [location(latitude: .nan), location(horizontal: -1), location(vertical: .infinity)] {
            XCTAssertNil(WorkoutRoutePoint.convert(invalid, route: route, index: 0))
        }
    }

    func testUnknownAltitudeAlonePreservesCoordinateAsNull() throws {
        let point = try XCTUnwrap(WorkoutRoutePoint.convert(location(altitude: .nan), route: route, index: 0))
        XCTAssertNil(point.altitude)
        XCTAssertEqual(point.latitude, 40)
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(point)) as! [String: Any]
        XCTAssertTrue(object["altitude"] is NSNull)
    }

    func testRoutePagingContractMatchesLowercaseDatabaseResponse() async throws {
        let user = UUID().uuidString.lowercased()
        let payload = try JSONSerialization.data(withJSONObject: ["sub": user]).base64EncodedString()
        let identity = WorkoutDetailIdentity(endpoint: "https://example.invalid/functions/v1/healthkit-ingest",
            userID: user, connectionRevision: 1, signOutGeneration: 1)
        let descriptor = WorkoutRouteDescriptor(routeUUID: route.uuidString.lowercased(), sourceCount: 502)
        var sizes: [Int] = [], count = 0
        let client = WorkoutDetailClient(identity: identity, token: { "e30.\(payload).signature" }, validate: {},
            resource: .routes, transport: { request in
                XCTAssertEqual(request.url?.lastPathComponent, "workout-routes")
                let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
                let id = (body["export_uuid"] as? String ?? "").lowercased()
                let response: [String: Any]
                switch body["operation"] as! String {
                case "capabilities": response = ["capabilities": ["workout_routes_v1"]]
                case "begin": response = ["export_uuid": id, "complete": false]
                case "page":
                    let size = (body["points"] as! [Any]).count; sizes.append(size); count += size
                    response = ["observed_count": count]
                default: response = ["export_uuid": id, "complete": true, "observed_count": count,
                    "coverage": "observed_only", "invalid_counts": body["invalid_counts"]!]
                }
                return (try JSONSerialization.data(withJSONObject: response),
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            })
        let result = try await WorkoutRouteExport.run(workoutID: UUID(), routes: [descriptor], client: client, validate: {}) { _ in
            let collector = WorkoutRouteCollector(routeID: self.route, expected: 502)
            let locations = [self.location(latitude: 200)] + Array(repeating: self.location(), count: 501)
            return try XCTUnwrap(collector.append(locations, done: true))
        }
        XCTAssertEqual(result, WorkoutRouteSummary(valid: 501, invalid: 1))
        XCTAssertEqual(result.source, 502)
        XCTAssertEqual(sizes, [500, 1])
    }

    func testDisabledRouteCapabilityDoesNotReadOrBegin() async throws {
        let user = UUID().uuidString.lowercased()
        let payload = try JSONSerialization.data(withJSONObject: ["sub": user]).base64EncodedString()
        let identity = WorkoutDetailIdentity(endpoint: "https://example.invalid/functions/v1/healthkit-ingest",
            userID: user, connectionRevision: 1, signOutGeneration: 1)
        var posts = 0, reads = 0
        let client = WorkoutDetailClient(identity: identity, token: { "e30.\(payload).signature" }, validate: {},
            resource: .routes, transport: { request in
                posts += 1
                return (Data("{\"capabilities\":[]}".utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            })
        do {
            _ = try await WorkoutRouteExport.run(workoutID: UUID(), routes: [], client: client, validate: {}) { _ in
                reads += 1; return WorkoutRouteObservation(points: [], invalidCount: 0)
            }
            XCTFail()
        } catch { XCTAssertEqual(posts, 1); XCTAssertEqual(reads, 0) }
    }

    func testAllInvalidStillReportsObservedSourceCount() throws {
        let observation = try XCTUnwrap(WorkoutRouteCollector(routeID: route, expected: 2)
            .append([location(horizontal: -1), location(latitude: 200)], done: true))
        let summary = WorkoutRouteSummary(valid: observation.points.count, invalid: observation.invalidCount)
        XCTAssertEqual(summary.valid, 0)
        XCTAssertEqual(summary.invalid, 2)
        XCTAssertEqual(summary.source, 2)
    }
}
