import XCTest
@testable import Health4AI

// Fixtures are real shapes from the Pi (peloton_pi/ride.py summary() + samples; GET /api/rides).

private let listJSON = """
{"rides": [{"id": "20261102T172446Z", "started": 1793640286.157636, "elapsed": 125, "output_kj": 26.5, "calories": 25, "distance_mi": 0.63, "avg": {"cadence": 69, "power": 233, "resistance": 58, "hr": 0}, "best": {"cadence": 100, "power": 397, "resistance": 58.0, "hr": 0}, "zone_seconds": [125, 0, 0, 0, 0, 0]}], "records": {"rides": 1}}
"""

private func detailJSON(id: String = "20261102T172230Z", elapsed: Int = 12, samples: String) -> String {
    """
    {"summary": {"id": "\(id)", "started": 1793640150.25, "elapsed": \(elapsed), "output_kj": 3.0, "calories": 3, "distance_mi": 0.1,
     "avg": {"cadence": 52, "power": 136, "resistance": 58, "hr": 0}, "best": {"cadence": 70, "power": 215, "resistance": 58.0, "hr": 0},
     "zone_seconds": [12, 0, 0, 0, 0, 0]}, "samples": \(samples)}
    """
}

private func ride(id: String = "20261102T172230Z", seconds: Int = 12, hr: Double = 0) -> BikeRide {
    let samples = (0...seconds).map { BikeRideSample(t: $0, cadence: 60, power: 100, resistance: 58, speedMph: 15, hr: hr) }
    return BikeRide(summary: BikeRideSummary(id: id, elapsed: seconds, outputKJ: 1.2, calories: 10, distanceMi: 0.25), samples: samples)
}

final class BikeURLTests: XCTestCase {
    func ok(_ s: String, _ expect: String? = nil, line: UInt = #line) {
        switch BikeURLValidator.validate(s) {
        case .success(let u): if let expect { XCTAssertEqual(u.absoluteString, expect, line: line) }
        case .failure(let e): XCTFail("\(s) rejected: \(e)", line: line)
        }
    }
    func bad(_ s: String, _ expect: BikeURLError? = nil, line: UInt = #line) {
        switch BikeURLValidator.validate(s) {
        case .success(let u): XCTFail("\(s) accepted as \(u)", line: line)
        case .failure(let e): if let expect { XCTAssertEqual(e, expect, line: line) }
        }
    }

    func testAccepts() {
        ok("http://peloton-pi.local:8080", "http://peloton-pi.local:8080")
        ok("http://10.7.1.187:8080/", "http://10.7.1.187:8080")
        ok("https://192.168.1.20")
        ok("http://172.16.0.1")
        ok("http://172.31.255.254")
        ok("http://169.254.10.10")
        ok("HTTP://Bike.LOCAL./")
        ok("peloton-pi.local:8080", "http://peloton-pi.local:8080")
        ok("http://[fe80::1]:8080")
    }

    func testRejectsPublicHosts() {
        bad("http://example.com", .publicHost("example.com"))
        bad("http://8.8.8.8")
        bad("http://172.32.0.1")
        bad("http://172.15.0.1")
        bad("http://192.169.1.1")
        bad("http://11.0.0.1")
        bad("http://127.0.0.1")
        bad("http://localhost")
        bad("http://local")
        bad("http://.local")
        bad("http://10.0.0.1.evil.com")
        bad("http://peloton.local.evil.com")
        bad("http://evil.com/.local")
        bad("http://[2001:db8::1]")
        bad("http://010.0.0.1x")
        bad("http://10.0.0.256")
    }

    func testRejectsOtherShapes() {
        bad("", .empty)
        bad("   ", .empty)
        bad("ftp://peloton-pi.local", .badScheme)
        bad("file:///etc/passwd", .badScheme)
        bad("http://user:pw@peloton-pi.local", .credentialsNotAllowed)
        bad("http://peloton-pi.local/?x=1", .queryNotAllowed)
    }
}

final class BikeParsingTests: XCTestCase {
    func testListParses() throws {
        let list = try JSONDecoder().decode(BikeRideList.self, from: Data(listJSON.utf8))
        XCTAssertEqual(list.rides.count, 1)
        XCTAssertEqual(list.rides[0], BikeRideSummary(id: "20261102T172446Z", elapsed: 125, outputKJ: 26.5, calories: 25, distanceMi: 0.63))
    }

    func testDetailParsesNullResistanceAndHR() throws {
        let json = detailJSON(samples: "[[0, 23, 0, 57.8, 0.0, 0], [1, 14, 9, null, 4.1, 132]]")
        let r = try JSONDecoder().decode(BikeRide.self, from: Data(json.utf8))
        XCTAssertEqual(r.samples.count, 2)
        XCTAssertEqual(r.samples[0].resistance, 57.8)
        XCTAssertNil(r.samples[1].resistance)
        XCTAssertEqual(r.samples[1].hr, 132)
        XCTAssertEqual(r.samples[1].speedMph, 4.1)
    }

    func testShortSampleRowFails() {
        let json = detailJSON(samples: "[[0, 23, 0]]")
        XCTAssertThrowsError(try JSONDecoder().decode(BikeRide.self, from: Data(json.utf8)))
    }

    func testNonPiJSONFails() {
        XCTAssertThrowsError(try JSONDecoder().decode(BikeRideList.self, from: Data("{\"hello\": 1}".utf8)))
    }
}

final class BikeIdentityTests: XCTestCase {
    func testDateFromID() {
        let d = BikeRideID.startDate(from: "20261102T172230Z")
        XCTAssertEqual(d?.timeIntervalSince1970, 1793640150)   // matches the Pi's `started` for this ride
    }

    func testBadIDs() {
        for id in ["", "20261102", "20261102T172230", "20261302T172230Z", "20261131T172230Z", "20261102T252230Z",
                   "2026110aT172230Z", "20261102X172230Z", "../etc/passwd", "20261102T172230Z/../x"] {
            XCTAssertNil(BikeRideID.startDate(from: id), id)
        }
    }

    func testSyncIdentifierIsStableAndHostFree() {
        XCTAssertEqual(BikeRideID.syncIdentifier(for: "20261102T172230Z"), "com.health4ai.pelotonpi:20261102T172230Z")
        XCTAssertNotEqual(BikeRideID.syncIdentifier(for: "20261102T172230Z"), BikeRideID.syncIdentifier(for: "20261102T172446Z"))
    }
}

final class BikeAggregationTests: XCTestCase {
    func samples(_ n: Int, hr: (Int) -> Double = { _ in 0 }) -> [BikeRideSample] {
        (0...n).map { BikeRideSample(t: $0, cadence: Double($0), power: 100, speedMph: 10, hr: hr($0)) }
    }

    func testFiveSecondBucketsNeverPastEnd() {
        let b = BikeSampleAggregator.buckets(samples: samples(125), elapsed: 125)
        XCTAssertEqual(b.count, 25)
        XCTAssertEqual(b.first?.startOffset, 0)
        XCTAssertEqual(b.last?.endOffset, 125)   // t=125 is folded into the last bucket
        for (x, y) in zip(b, b.dropFirst()) { XCTAssertEqual(x.endOffset, y.startOffset) }
    }

    func testBucketMeans() {
        let b = BikeSampleAggregator.buckets(samples: samples(9), elapsed: 10)
        XCTAssertEqual(b.count, 2)
        XCTAssertEqual(b[0].cadence, 2.0, accuracy: 1e-9)   // mean of 0...4
        XCTAssertEqual(b[1].cadence, 7.0, accuracy: 1e-9)   // mean of 5...9
        XCTAssertEqual(b[0].power, 100)
    }

    func testHeartRateIgnoresZeros() {
        let b = BikeSampleAggregator.buckets(samples: samples(9) { $0 == 1 ? 140 : ($0 == 3 ? 150 : 0) }, elapsed: 10)
        XCTAssertEqual(b[0].heartRate!, 145, accuracy: 1e-9)
        XCTAssertNil(b[1].heartRate)
    }

    func testNoSamples() {
        XCTAssertTrue(BikeSampleAggregator.buckets(samples: [], elapsed: 60).isEmpty)
    }

    func testAllocationSumsToTotal() {
        let b = BikeSampleAggregator.buckets(samples: samples(125), elapsed: 125)
        let kcal = BikeSampleAggregator.allocate(total: 25, over: b, weight: \.workWeight)
        XCTAssertEqual(kcal.reduce(0, +), 25, accuracy: 1e-9)
        let zero = BikeSampleAggregator.buckets(samples: (0...9).map { BikeRideSample(t: $0, cadence: 0, power: 0, speedMph: 0, hr: 0) }, elapsed: 10)
        XCTAssertEqual(BikeSampleAggregator.allocate(total: 4, over: zero, weight: \.workWeight).reduce(0, +), 4, accuracy: 1e-9)
    }

    func testPlanTimesAndTotals() throws {
        let plan = try BikeWorkoutPlan.make(from: ride(seconds: 12))
        XCTAssertEqual(plan.start.timeIntervalSince1970, 1793640150)
        XCTAssertEqual(plan.end.timeIntervalSince(plan.start), 12)
        XCTAssertEqual(plan.totalMeters, 0.25 * 1609.344, accuracy: 1e-6)
        XCTAssertEqual(plan.metersPerBucket.reduce(0, +), plan.totalMeters, accuracy: 1e-6)
        XCTAssertFalse(plan.hasHeartRate)
    }
}

// MARK: - Importer with fakes

private final class FakeAPI: BikeRideAPI {
    var list: Result<[BikeRideSummary], Error> = .success([])
    var rides: [String: BikeRide] = [:]
    var detailCalls: [String] = []
    func listRides() async throws -> [BikeRideSummary] { try list.get() }
    func ride(id: String) async throws -> BikeRide {
        detailCalls.append(id)
        guard let r = rides[id] else { throw BikeClientError.http(status: 404, path: "/api/rides/\(id)") }
        return r
    }
}

private final class FakeStore: BikeWorkoutStore {
    var coreAccess = BikeCoreAccess()
    var unconfirmedIDs: Set<String> = []     // save "succeeds" in Health only for others; these throw saveUnconfirmed
    var heartRateWriteStatus: BikeWriteStatus = .notDetermined
    var healthKit: Set<String> = []          // stands in for Health: persists across "reinstalls"
    var saved: [BikeWorkoutPlan] = []
    var failSaves = false
    var rawError: Error?
    var hrRequests = 0
    func requestCoreAuthorization() async throws {}
    func requestHeartRateAuthorization() async throws { hrRequests += 1; heartRateWriteStatus = .authorized }
    func existingSyncIdentifiers(among ids: [String]) async throws -> Set<String> { healthKit.intersection(ids) }
    func save(_ plan: BikeWorkoutPlan) async throws {
        if let rawError { throw rawError }
        if failSaves { throw BikeImportError.coreAccessMissing(["Workouts"]) }
        if unconfirmedIDs.contains(plan.rideID) { throw BikeImportError.saveUnconfirmed(plan.rideID) }
        saved.append(plan)
        healthKit.insert(plan.syncIdentifier)
    }
}

final class BikeImporterTests: XCTestCase {
    private func setUpAPI(_ rides: [BikeRide]) -> FakeAPI {
        let api = FakeAPI()
        api.list = .success(rides.map(\.summary))
        for r in rides { api.rides[r.summary.id] = r }
        return api
    }

    func testImportsNewRideOnce() async {
        let r = ride()
        let api = setUpAPI([r]); let store = FakeStore()
        let first = await BikeImporter(api: api, store: store).run()
        XCTAssertEqual(first.imported, 1)
        XCTAssertTrue(first.isSuccess)
        XCTAssertEqual(store.saved.first?.syncIdentifier, "com.health4ai.pelotonpi:20261102T172230Z")
        let second = await BikeImporter(api: api, store: store).run()   // a fresh importer = app relaunch/reinstall
        XCTAssertEqual(second.imported, 0)
        XCTAssertEqual(second.alreadyImported, 1)
        XCTAssertEqual(store.saved.count, 1)
        XCTAssertEqual(api.detailCalls.count, 1, "an already-imported ride must not even be fetched")
    }

    func testFailedSaveIsNotMarkedImported() async {
        let api = setUpAPI([ride()]); let store = FakeStore()
        store.failSaves = true
        let failed = await BikeImporter(api: api, store: store).run()
        XCTAssertEqual(failed.imported, 0)
        XCTAssertEqual(failed.failed.count, 1)
        XCTAssertFalse(failed.isSuccess)
        store.failSaves = false
        let retry = await BikeImporter(api: api, store: store).run()
        XCTAssertEqual(retry.imported, 1)
    }

    func testRideWithNoSamplesIsSkippedWithReason() async {
        let empty = BikeRide(summary: BikeRideSummary(id: "20261102T172230Z", elapsed: 90, outputKJ: 0, calories: 0, distanceMi: 0), samples: [])
        let store = FakeStore()
        let r = await BikeImporter(api: setUpAPI([empty]), store: store).run()
        XCTAssertEqual(r.imported, 0)
        XCTAssertEqual(r.skipped.count, 1)
        XCTAssertTrue(r.skipped[0].reason.contains("no samples"))
        XCTAssertTrue(store.saved.isEmpty)
        XCTAssertNil(r.error)
    }

    func testNetworkErrorIsAnErrorNotSuccess() async {
        let api = FakeAPI()
        api.list = .failure(BikeClientError.unreachable(host: "peloton-pi.local", detail: "offline"))
        let r = await BikeImporter(api: api, store: FakeStore()).run()
        XCTAssertNotNil(r.error)
        XCTAssertFalse(r.isSuccess)
        XCTAssertEqual(r.imported, 0)
    }

    func testDeniedPermissionStopsBeforeAnyNetwork() async {
        let api = setUpAPI([ride()]); let store = FakeStore()
        store.coreAccess = BikeCoreAccess(denied: ["Workouts"])
        let r = await BikeImporter(api: api, store: store).run()
        XCTAssertNotNil(r.error)
        XCTAssertTrue(api.detailCalls.isEmpty)
    }

    /// Each core type on its own must block the import, because a ride saved without it would hold the
    /// sync identifier and never get that metric later.
    func testImporterRefusesWhenAnyCoreTypeIsNotAuthorized() async {
        for name in ["Workouts", "Active energy", "Cycling distance", "Cycling power", "Cycling cadence"] {
            for access in [BikeCoreAccess(denied: [name]), BikeCoreAccess(notDetermined: [name])] {
                let api = setUpAPI([ride()]); let store = FakeStore()
                store.coreAccess = access
                let r = await BikeImporter(api: api, store: store).run()
                XCTAssertNotNil(r.error, name)
                XCTAssertEqual(r.imported, 0, name)
                XCTAssertTrue(store.saved.isEmpty, name)
                XCTAssertTrue(api.detailCalls.isEmpty, name)
            }
        }
        let denied = await BikeImporter(api: setUpAPI([ride()]), store: { let s = FakeStore(); s.coreAccess = BikeCoreAccess(denied: ["Cycling power"]); return s }()).run()
        XCTAssertTrue(denied.error?.contains("Cycling power") ?? false, "names the missing type")
    }

    func testUnconfirmedSaveIsNeitherImportedNorFailed() async {
        let store = FakeStore(); store.unconfirmedIDs = ["20261102T172230Z"]
        let r = await BikeImporter(api: setUpAPI([ride()]), store: store).run()
        XCTAssertEqual(r.imported, 0)
        XCTAssertEqual(r.unconfirmed.count, 1)
        XCTAssertTrue(r.failed.isEmpty)
        XCTAssertFalse(r.isSuccess)
        store.unconfirmedIDs = []
        let again = await BikeImporter(api: setUpAPI([ride()]), store: store).run()   // re-checked next import
        XCTAssertEqual(again.imported, 1)
    }

    func testInvalidRideIsSkippedWithReasonAndNothingSaved() async {
        let wild = BikeRide(summary: BikeRideSummary(id: "20261102T172230Z", elapsed: 10, outputKJ: 1, calories: 10, distanceMi: 0.1),
                            samples: [BikeRideSample(t: 0, cadence: 60, power: 1e9, speedMph: 10, hr: 0)])
        let store = FakeStore()
        let r = await BikeImporter(api: setUpAPI([wild]), store: store).run()
        XCTAssertEqual(r.skipped.count, 1)
        XCTAssertTrue(r.skipped[0].reason.contains("power"))
        XCTAssertTrue(store.saved.isEmpty)
    }

    func testRidesPerImportAreCapped() async {
        let rides = (0..<5).map { ride(id: String(format: "20261102T17%02d00Z", 10 + $0)) }
        let store = FakeStore()
        var importer = BikeImporter(api: setUpAPI(rides), store: store)
        importer.maxRides = 3
        let r = await importer.run()
        XCTAssertEqual(r.imported, 3)
        XCTAssertEqual(r.notes.count, 1)
        let rest = await BikeImporter(api: setUpAPI(rides), store: store).run()   // the remainder follows next time
        XCTAssertEqual(rest.imported, 2)
        XCTAssertEqual(rest.alreadyImported, 3)
    }

    func testOneBadRideDoesNotBlockTheOthers() async {
        let good = ride(id: "20261102T172446Z")
        let api = setUpAPI([ride(id: "20261102T172230Z"), good])
        api.rides["20261102T172230Z"] = nil   // listed but detail 404s
        let r = await BikeImporter(api: api, store: FakeStore()).run()
        XCTAssertEqual(r.imported, 1)
        XCTAssertEqual(r.failed.count, 1)
    }

    func testHeartRateRequestedOnlyWhenRideHasIt() async {
        let store = FakeStore()
        _ = await BikeImporter(api: setUpAPI([ride(hr: 0)]), store: store).run()
        XCTAssertEqual(store.hrRequests, 0)
        XCTAssertEqual(store.saved.first?.writeHeartRate, false)

        let store2 = FakeStore()
        _ = await BikeImporter(api: setUpAPI([ride(hr: 140)]), store: store2).run()
        XCTAssertEqual(store2.hrRequests, 1)
        XCTAssertEqual(store2.saved.first?.writeHeartRate, true)
    }

    func testHeartRateDeniedStillImportsWithNote() async {
        let store = FakeStore()
        store.heartRateWriteStatus = .denied
        let r = await BikeImporter(api: setUpAPI([ride(hr: 140)]), store: store).run()
        XCTAssertEqual(r.imported, 1)
        XCTAssertEqual(store.saved.first?.writeHeartRate, false)
        XCTAssertEqual(r.notes.count, 1)
        XCTAssertTrue(r.notes[0].reason.contains("will not get it later"))
    }

    /// Raw HealthKit/NSError text must never reach the screen; it is logged instead.
    func testHealthKitErrorTextNeverReachesTheVisibleReason() async {
        let store = FakeStore()
        store.rawError = NSError(domain: "com.apple.healthkit", code: 5, userInfo: [NSLocalizedDescriptionKey: "HKErrorDomain code 5 raw"])
        let r = await BikeImporter(api: setUpAPI([ride()]), store: store).run()
        XCTAssertEqual(r.failed.count, 1)
        let shown = r.failed[0].reason.lowercased()
        XCTAssertFalse(shown.contains("healthkit"))
        XCTAssertFalse(shown.contains("domain"))
        XCTAssertFalse(shown.contains("code 5"))
        XCTAssertFalse(shown.contains("20261102T172230Z"), "no raw ride id")
    }

    func testIssueSummaryNamesAtMostThreeRidesByDate() {
        let ids = ["20261101T100000Z", "20261102T100000Z", "20261103T100000Z", "20261104T100000Z", "20261105T100000Z"]
        let issues = ids.map { BikeIssue(rideID: $0, reason: "same reason") }
        let s = BikeIssueSummary(issues, format: { "D\($0.timeIntervalSince1970)" })!
        XCTAssertEqual(s.count, 5)
        XCTAssertEqual(s.rides.count, 3)
        XCTAssertEqual(s.more, 2)
        XCTAssertEqual(s.reason, "same reason")
        XCTAssertEqual(s.otherReasons, 0)
        XCTAssertTrue(s.rides.allSatisfy { !$0.contains("2026110") }, "dates are formatted, never raw ids")
    }

    func testIssueSummaryGroupsByMostCommonReason() {
        let issues = [BikeIssue(rideID: "20261101T100000Z", reason: "a"), BikeIssue(rideID: "20261102T100000Z", reason: "b"),
                      BikeIssue(rideID: "20261103T100000Z", reason: "b")]
        let s = BikeIssueSummary(issues, format: { _ in "x" })!
        XCTAssertEqual(s.reason, "b")
        XCTAssertEqual(s.otherReasons, 1)
        XCTAssertNil(BikeIssueSummary([], format: { _ in "x" }))
    }
}
