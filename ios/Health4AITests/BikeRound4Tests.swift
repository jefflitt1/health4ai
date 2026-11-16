import XCTest
@testable import Health4AI

// Round 4: a remembered rejection must never permanently lose a good ride.

private final class Clock { var back = false }

private func serve(_ rides: [BikeRide]) -> FakeAPI {
    let a = FakeAPI()
    a.list = .success(rides.map(\.summary))
    for r in rides { a.rides[r.summary.id] = r }
    return a
}

final class BikeRejectionSafetyTests: XCTestCase {
    private let id = "20260301T100000Z"

    private func invalidRide(elapsed: Int = 10, calories: Double = 1) -> BikeRide {
        BikeRide(summary: BikeRideSummary(id: id, elapsed: elapsed, outputKJ: 1, calories: calories, distanceMi: 0.1),
                 samples: [BikeRideSample(t: 0, cadence: 60, power: 1e9, speedMph: 10, hr: 0)])
    }

    /// U1: the file for an id changes (corrected, or finished since): the listing changes, so it is fetched again.
    func testAChangedSummaryIsRefetchedAndImports() async {
        let remembered = MemoryRejectedStore()
        var first = BikeImporter(api: serve([invalidRide()]), store: FakeStore()); first.rejectedStore = remembered
        let r1 = await first.run()
        XCTAssertEqual(r1.skipped.count, 1)
        XCTAssertEqual(remembered.load().count, 1, "a settled content rejection is remembered")

        // Same id, but the bike now lists different numbers and serves a good file.
        let corrected = ride(id: id)
        XCTAssertNotEqual(corrected.summary, invalidRide().summary)
        let api2 = serve([corrected]); let store = FakeStore()
        var second = BikeImporter(api: api2, store: store); second.rejectedStore = remembered
        let r2 = await second.run()
        XCTAssertEqual(api2.detailCalls, [id], "the changed summary forces a refetch")
        XCTAssertEqual(r2.imported, 1)
        XCTAssertTrue(remembered.load().isEmpty, "the stale rejection is dropped once the ride imports")
    }

    func testAnUnchangedSummaryIsStillNotRefetched() async {
        let remembered = MemoryRejectedStore()
        var first = BikeImporter(api: serve([invalidRide()]), store: FakeStore()); first.rejectedStore = remembered
        _ = await first.run()
        let api2 = serve([invalidRide()])
        var second = BikeImporter(api: api2, store: FakeStore()); second.rejectedStore = remembered
        _ = await second.run()
        XCTAssertTrue(api2.detailCalls.isEmpty)
    }

    /// U1: a ride that just ended may still be being written; do not trust a rejection yet.
    func testJustEndedRideRejectedForNoSamplesIsNotRemembered() async {
        let start = BikeRideID.startDate(from: id)!
        let empty = BikeRide(summary: BikeRideSummary(id: id, elapsed: 60, outputKJ: 0, calories: 0, distanceMi: 0), samples: [])
        for (offset, expectRemembered) in [(5 * 60.0, false), (3600.0, true)] {   // ended 4 min ago, then 59 min ago
            let remembered = MemoryRejectedStore()
            var importer = BikeImporter(api: serve([empty]), store: FakeStore())
            importer.rejectedStore = remembered
            importer.now = { start.addingTimeInterval(offset) }
            let r = await importer.run()
            XCTAssertEqual(r.skipped.count, 1)
            XCTAssertEqual(!remembered.load().isEmpty, expectRemembered, "offset \(offset)")
        }
    }

    /// U2: the key follows the limit values, with nothing bumped by hand.
    func testChangingALimitChangesTheKey() {
        let entries = BikeLimits.entries
        XCTAssertEqual(BikeLimits.key(for: entries), BikeLimits.rulesKey)
        XCTAssertEqual(BikeLimits.rulesKey, BikeLimits.rulesKey, "stable between calls")
        for i in entries.indices {
            var changed = entries
            changed[i].value += "x"
            XCTAssertNotEqual(BikeLimits.key(for: changed), BikeLimits.rulesKey, "changing \(entries[i].name) must change the key")
        }
        let names = Set(entries.map(\.name))
        for n in ["power", "cadence", "heartRate", "speed", "elapsed", "calories", "distance", "earliestRide", "maxSamplesPerRide"] {
            XCTAssertTrue(names.contains(n), n)
        }
    }

    /// U3: if the clock moves back between the prefilter and the validator, the date failure is not remembered.
    func testADateFailureReachingTheValidatorIsNotRemembered() async {
        let start = BikeRideID.startDate(from: "20261001T100000Z")!
        let good = ride(id: "20261001T100000Z")
        let clock = Clock()
        let api = serve([good]); api.onRide = { clock.back = true }
        let remembered = MemoryRejectedStore()
        var importer = BikeImporter(api: api, store: FakeStore()); importer.rejectedStore = remembered
        importer.now = { clock.back ? start.addingTimeInterval(-3 * 86_400) : start.addingTimeInterval(3600) }
        let r = await importer.run()
        XCTAssertEqual(r.imported, 0)
        XCTAssertEqual(r.skipped.count, 1)
        XCTAssertTrue(r.skipped[0].reason.contains("date"), r.skipped[0].reason)
        XCTAssertTrue(remembered.load().isEmpty, "a clock-dependent failure must never be remembered")
    }
}
