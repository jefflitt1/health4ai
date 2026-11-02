import XCTest
@testable import Health4AI

// MARK: - Review fixes

final class BikeReviewFixTests: XCTestCase {
    func sampleJSON(_ t: String) -> Data {
        Data("{\"summary\": {\"id\": \"20261102T172230Z\", \"elapsed\": 10, \"output_kj\": 1, \"calories\": 1, \"distance_mi\": 0.1}, \"samples\": [[\(t), 1, 1, null, 1, 0]]}".utf8)
    }

    func testHugeSampleTimeThrowsInsteadOfTrapping() {
        for t in ["1e30", "-5", "1e12", "1e308"] {
            XCTAssertThrowsError(try JSONDecoder().decode(BikeRide.self, from: sampleJSON(t)), t)
        }
        XCTAssertNoThrow(try JSONDecoder().decode(BikeRide.self, from: sampleJSON("3")))
    }

    func testValidatorBounds() throws {
        let start = BikeRideID.startDate(from: "20261102T172230Z")!
        let now = start.addingTimeInterval(3600)
        func rideWith(power: Double = 100, cadence: Double = 60, hr: Double = 0, speed: Double = 10, elapsed: Int = 10,
                      kcal: Double = 10, miles: Double = 0.1, id: String = "20261102T172230Z") -> BikeRide {
            BikeRide(summary: BikeRideSummary(id: id, elapsed: elapsed, outputKJ: 1, calories: kcal, distanceMi: miles),
                     samples: [BikeRideSample(t: 0, cadence: cadence, power: power, speedMph: speed, hr: hr)])
        }
        XCTAssertNoThrow(try BikeWorkoutPlan.make(from: rideWith(), now: now))
        XCTAssertNoThrow(try BikeWorkoutPlan.make(from: rideWith(power: 3000, cadence: 250, hr: 250, speed: 80, elapsed: 86_400, kcal: 5000, miles: 200), now: now))
        let bad: [(String, BikeRide)] = [
            ("power", rideWith(power: 3001)), ("negative power", rideWith(power: -1)),
            ("cadence", rideWith(cadence: 251)), ("hr low", rideWith(hr: 20)), ("hr high", rideWith(hr: 251)),
            ("speed", rideWith(speed: 81)), ("elapsed zero", rideWith(elapsed: 0)), ("elapsed big", rideWith(elapsed: 86_401)),
            ("kcal", rideWith(kcal: 5001)), ("kcal negative", rideWith(kcal: -1)), ("miles", rideWith(miles: 201)),
            ("nan", rideWith(power: .nan)), ("inf", rideWith(speed: .infinity)),
            ("old date", rideWith(id: "20141231T235959Z")), ("future date", rideWith(id: "20261105T000000Z")),
        ]
        for (name, ride) in bad {
            XCTAssertThrowsError(try BikeWorkoutPlan.make(from: ride, now: now), name) { error in
                guard case BikeImportError.invalidRide = error else { return XCTFail("\(name): \(error)") }
            }
        }
        let tooMany = BikeRide(summary: BikeRideSummary(id: "20261102T172230Z", elapsed: 10, outputKJ: 1, calories: 1, distanceMi: 0.1),
                               samples: Array(repeating: BikeRideSample(t: 0, cadence: 1, power: 1, speedMph: 1, hr: 0), count: BikeLimits.maxSamplesPerRide + 1))
        XCTAssertThrowsError(try BikeWorkoutPlan.make(from: tooMany, now: now))
    }

    func testEveryPlannedSampleLiesWithinTheWorkout() throws {
        // Samples stop at 30 s but the ride was 60 s long: the workout must still cover 60 s.
        let samples = (0...30).map { BikeRideSample(t: $0, cadence: 60, power: 100, speedMph: 10, hr: 120) }
        let r = BikeRide(summary: BikeRideSummary(id: "20261102T172230Z", elapsed: 60, outputKJ: 1, calories: 20, distanceMi: 0.2), samples: samples)
        let plan = try BikeWorkoutPlan.make(from: r, now: plan0Now)
        XCTAssertEqual(plan.end.timeIntervalSince(plan.start), 60, "end = start + elapsed")
        for b in plan.buckets {
            XCTAssertGreaterThanOrEqual(plan.start.addingTimeInterval(TimeInterval(b.startOffset)), plan.start)
            XCTAssertLessThanOrEqual(plan.start.addingTimeInterval(TimeInterval(b.endOffset)), plan.end)
        }
        // And when a sample sits one second past elapsed (Pi rounding), nothing escapes either.
        let edge = BikeRide(summary: BikeRideSummary(id: "20261102T172230Z", elapsed: 10, outputKJ: 1, calories: 1, distanceMi: 0.1),
                            samples: (0...11).map { BikeRideSample(t: $0, cadence: 1, power: 1, speedMph: 1, hr: 0) })
        let p2 = try BikeWorkoutPlan.make(from: edge, now: plan0Now)
        XCTAssertEqual(p2.buckets.last?.endOffset, 10)
        XCTAssertLessThanOrEqual(p2.buckets.map(\.endOffset).max()!, 10)
    }

    private var plan0Now: Date { BikeRideID.startDate(from: "20261102T172230Z")!.addingTimeInterval(3600) }

    func testIPv4LeadingZerosRejected() {
        for h in ["172.016.0.1", "010.0.0.1", "192.168.001.1", "10.00.0.1", "169.254.01.1"] {
            if case .success = BikeURLValidator.validate("http://\(h)") { XCTFail("\(h) accepted") }
        }
        if case .failure(let e) = BikeURLValidator.validate("http://10.0.0.1") { XCTFail("\(e)") }
    }

    func testClientIsReleasedAfterUse() {
        weak var weakClient: BikeHTTPClient?
        autoreleasepool {
            let client = BikeHTTPClient(baseURL: URL(string: "http://peloton-pi.local:8080")!)
            weakClient = client
        }
        XCTAssertNil(weakClient, "a client (and its URLSession) must not be kept alive by its own delegate")
    }

    func testDeclaredContentLengthOverCapIsRefused() async {
        StubProtocol.handler = { _ in (200, ["Content-Length": "9999999"], Data("{\"rides\": []}".utf8)) }
        let client = BikeHTTPClient(baseURL: URL(string: "http://peloton-pi.local:8080")!, maxBytes: 1024, protocolClasses: [StubProtocol.self])
        do { _ = try await client.listRides(); XCTFail("accepted") } catch { XCTAssertEqual(error as? BikeClientError, .tooLarge) }
    }

    func testStreamedBodyOverCapIsRefused() async {
        StubProtocol.handler = { _ in (200, [:], Data(repeating: 0x20, count: 5000)) }
        let client = BikeHTTPClient(baseURL: URL(string: "http://peloton-pi.local:8080")!, maxBytes: 1024, protocolClasses: [StubProtocol.self])
        do { _ = try await client.listRides(); XCTFail("accepted") } catch { XCTAssertEqual(error as? BikeClientError, .tooLarge) }
    }

    func testSmallBodyAndRedirectBehaviour() async throws {
        StubProtocol.handler = { _ in (200, [:], Data("{\"rides\": []}".utf8)) }
        let client = BikeHTTPClient(baseURL: URL(string: "http://peloton-pi.local:8080")!, protocolClasses: [StubProtocol.self])
        let rides = try await client.listRides()
        XCTAssertTrue(rides.isEmpty)
        StubProtocol.handler = { _ in (302, ["Location": "http://example.com/"], Data()) }
        do { _ = try await client.listRides(); XCTFail("followed") } catch { XCTAssertEqual(error as? BikeClientError, .redirectRefused) }
    }
}

final class StubProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, [String: String], Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, headers, body) = Self.handler!(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
