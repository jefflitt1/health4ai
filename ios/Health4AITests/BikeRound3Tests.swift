import XCTest
@testable import Health4AI

// Round 3: ordering and the per-import cap.

private func stamp(_ date: Date) -> String {
    let f = DateFormatter()
    f.calendar = Calendar(identifier: .gregorian); f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
    return f.string(from: date)
}

private func badRide(_ id: String) -> BikeRide {
    BikeRide(summary: BikeRideSummary(id: id, elapsed: 10, outputKJ: 1, calories: 1, distanceMi: 0.1),
             samples: [BikeRideSample(t: 0, cadence: 60, power: 1e9, speedMph: 10, hr: 0)])   // 1e9 W: always rejected
}

private func serve(_ rides: [BikeRide], extraSummaries: [BikeRideSummary] = []) -> FakeAPI {
    let a = FakeAPI()
    a.list = .success(rides.map(\.summary) + extraSummaries)
    for r in rides { a.rides[r.summary.id] = r }
    return a
}

final class BikeOrderingAndCapTests: XCTestCase {
    /// T1: ids that are not timestamps sort FIRST as strings. They must not use cap slots or hide real rides.
    func testGarbageIdsDoNotStarveARealRide() async {
        let garbage = (0..<250).map { BikeRideSummary(id: "zz-garbage-\($0)", elapsed: 10, outputKJ: 1, calories: 1, distanceMi: 0.1) }
        let good = ride(id: "20261001T100000Z")
        let api = serve([good], extraSummaries: garbage)
        let store = FakeStore()
        let r = await BikeImporter(api: api, store: store).run()
        XCTAssertEqual(r.imported, 1)
        XCTAssertEqual(api.detailCalls, ["20261001T100000Z"], "garbage ids cost no network call")
        XCTAssertEqual(r.skipped.count, 250)
        XCTAssertTrue(r.skipped.allSatisfy { $0.reason == "The bike gave an id health4ai cannot read" })
        XCTAssertTrue(r.notes.isEmpty, "no 'older rides were left' note: nothing was left")
    }

    func testOrderingUsesTheParsedDateNotTheString() async {
        let ids = ["20261001T100000Z", "20261003T100000Z", "20261002T100000Z"]
        let api = serve(ids.map { ride(id: $0) })
        var importer = BikeImporter(api: api, store: FakeStore())
        importer.maxRides = 2
        _ = await importer.run()
        XCTAssertEqual(api.detailCalls, ["20261003T100000Z", "20261002T100000Z"], "newest first")
    }

    func testRidesOutsideTheDateRangeAreSkippedWithoutAFetch() async {
        let api = serve([ride(id: "20141231T235959Z"), ride(id: "20271101T000000Z"), ride(id: "20261001T100000Z")])
        let r = await BikeImporter(api: api, store: FakeStore()).run()
        XCTAssertEqual(r.imported, 1)
        XCTAssertEqual(r.skipped.count, 2)
        XCTAssertEqual(api.detailCalls, ["20261001T100000Z"])
    }

    /// T2: the newest 250 rides always fail validation; an older good ride must still get in.
    func testRejectedRidesAreRememberedAndDoNotBlockOlderGoodRides() async {
        let base = BikeRideID.startDate(from: "20260601T000000Z")!
        let bad = (0..<250).map { badRide(stamp(base.addingTimeInterval(TimeInterval($0 * 600)))) }
        let good = ride(id: "20260301T100000Z")
        let remembered = MemoryRejectedStore()
        let store = FakeStore()

        let api1 = serve(bad + [good])
        var first = BikeImporter(api: api1, store: store); first.rejectedStore = remembered
        let r1 = await first.run()
        XCTAssertEqual(r1.imported, 0)
        XCTAssertEqual(r1.skipped.count, 200, "the first 200 are fetched, rejected, and shown once")
        XCTAssertEqual(api1.detailCalls.count, 200)

        let api2 = serve(bad + [good])
        var second = BikeImporter(api: api2, store: store); second.rejectedStore = remembered
        let r2 = await second.run()
        XCTAssertEqual(r2.imported, 1, "the older good ride imports on the second run")
        XCTAssertEqual(store.saved.first?.rideID, "20260301T100000Z")
        let refetched = Set(api2.detailCalls).intersection(Set(api1.detailCalls))
        XCTAssertTrue(refetched.isEmpty, "run 2 refetched \(refetched.count) rejected rides")
        XCTAssertEqual(api2.detailCalls.count, 51, "only the 50 not yet seen plus the good one")
        XCTAssertEqual(r2.skipped.count, 50, "each rejected ride is shown on the run that rejected it, not again")
    }

    func testRejectionIsOnlyForContentNotForFailures() async {
        let remembered = MemoryRejectedStore()
        let id = "20261001T100000Z"
        let api = serve([ride(id: id)]); api.rideError = BikeClientError.timedOut(host: "x")
        var importer = BikeImporter(api: api, store: FakeStore()); importer.rejectedStore = remembered
        _ = await importer.run()
        XCTAssertTrue(remembered.load().isEmpty, "a failed fetch is retried next time")
    }

    func testDefaultsStoreIsKeyedByTheRulesKey() {
        let suite = UserDefaults(suiteName: "bike-rejected-tests")!
        suite.removePersistentDomain(forName: "bike-rejected-tests")
        DefaultsRejectedStore(defaults: suite, rulesKey: "k1").save(["a": "x", "b": "y"])
        XCTAssertEqual(DefaultsRejectedStore(defaults: suite, rulesKey: "k1").load(), ["a": "x", "b": "y"])
        XCTAssertTrue(DefaultsRejectedStore(defaults: suite, rulesKey: "k2").load().isEmpty, "a new rules key re-checks everything")
        suite.removePersistentDomain(forName: "bike-rejected-tests")
    }

    func testIdsTheBikeNoLongerListsAreForgotten() async {
        let remembered = MemoryRejectedStore()
        remembered.save(["20260101T000000Z": "fingerprint"])
        var importer = BikeImporter(api: serve([ride(id: "20261001T100000Z")]), store: FakeStore())
        importer.rejectedStore = remembered
        _ = await importer.run()
        XCTAssertTrue(remembered.load().isEmpty)
    }
}
