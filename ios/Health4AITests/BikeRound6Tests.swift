import XCTest
@testable import Health4AI

// Round 6: a remembered rejection is bounded in time and cannot be defeated by an absurd elapsed.

private func serve(_ rides: [BikeRide]) -> FakeAPI {
    let a = FakeAPI()
    a.list = .success(rides.map(\.summary))
    for r in rides { a.rides[r.summary.id] = r }
    return a
}

final class BikeRejectionExpiryTests: XCTestCase {
    private let id = "20260301T100000Z"
    private var start: Date { BikeRideID.startDate(from: id)! }

    private func badRide(elapsed: Int = 10) -> BikeRide {
        BikeRide(summary: BikeRideSummary(id: id, elapsed: elapsed, outputKJ: 1, calories: 1, distanceMi: 0.1),
                 samples: [BikeRideSample(t: 0, cadence: 60, power: 1e9, speedMph: 10, hr: 0)])
    }

    /// W1: an absurd elapsed put "ended" in the far future, so the rejection was never remembered.
    func testAnAbsurdElapsedIsRejectedOnceAndNotRefetched() async {
        let remembered = MemoryRejectedStore()
        let now = start.addingTimeInterval(3600)
        var first = BikeImporter(api: serve([badRide(elapsed: 10_000_000)]), store: FakeStore()); first.rejectedStore = remembered
        first.now = { now }
        let r1 = await first.run()
        XCTAssertEqual(r1.skipped.count, 1)
        let api2 = serve([badRide(elapsed: 10_000_000)])
        var second = BikeImporter(api: api2, store: FakeStore()); second.rejectedStore = remembered
        second.now = { now }
        _ = await second.run()
        XCTAssertTrue(api2.detailCalls.isEmpty, "refetched \(api2.detailCalls)")
    }

    private func runAfter(_ age: TimeInterval, storedAt: Date?) async -> FakeAPI {
        let ride = badRide()
        let remembered = MemoryRejectedStore()
        remembered.save([id: BikeRejection(fingerprint: BikeFingerprint.of(ride.summary), at: storedAt)])
        let api = serve([ride])
        var importer = BikeImporter(api: api, store: FakeStore()); importer.rejectedStore = remembered
        let t = start.addingTimeInterval(86_400 * 100)
        importer.now = { t }
        _ = await importer.run()
        return api
    }

    /// W2: older than 30 days is judged again; younger is not.
    func testAnEntryOlderThanThirtyDaysIsRefetched() async {
        let t = start.addingTimeInterval(86_400 * 100)
        let api = await runAfter(0, storedAt: t.addingTimeInterval(-31 * 86_400))
        XCTAssertEqual(api.detailCalls, [id])
    }

    func testAnEntryYoungerThanThirtyDaysIsNotRefetched() async {
        let t = start.addingTimeInterval(86_400 * 100)
        let api = await runAfter(0, storedAt: t.addingTimeInterval(-29 * 86_400))
        XCTAssertTrue(api.detailCalls.isEmpty)
    }

    /// Migration: the round-4 form carried no date and counts as expired.
    func testAnEntryWithNoDateIsRefetched() async {
        let api = await runAfter(0, storedAt: nil)
        XCTAssertEqual(api.detailCalls, [id])
    }

    func testTheOldStoredFormIsStillReadable() {
        let suite = UserDefaults(suiteName: "bike-rejected-legacy")!
        suite.removePersistentDomain(forName: "bike-rejected-legacy")
        suite.set(["a": "fp"], forKey: "h4a.bike.rejected.k1")
        let loaded = DefaultsRejectedStore(defaults: suite, rulesKey: "k1").load()
        XCTAssertEqual(loaded["a"], BikeRejection(fingerprint: "fp", at: nil))
        XCTAssertFalse(loaded["a"]!.holds(for: "fp", now: Date()))
        suite.removePersistentDomain(forName: "bike-rejected-legacy")
    }

    func testTheExpiryFeedsTheRulesKey() {
        XCTAssertTrue(BikeLimits.entries.contains { $0.name == "rejectionExpiry" })
        XCTAssertEqual(BikeLimits.rejectionExpiry, 30 * 86_400)
    }
}
