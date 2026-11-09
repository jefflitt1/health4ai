import XCTest
@testable import Health4AI

// Round 2: unconfirmed saves, importer ordering and wording, and what the screen is allowed to say.

private let t0 = BikeRideID.startDate(from: "20261102T172230Z")!.addingTimeInterval(3600)

private func rideID(_ date: Date) -> String {
    let f = DateFormatter()
    f.calendar = Calendar(identifier: .gregorian); f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
    return f.string(from: date)
}

private func api(_ rides: [BikeRide]) -> FakeAPI {
    let a = FakeAPI()
    a.list = .success(rides.map(\.summary))
    for r in rides { a.rides[r.summary.id] = r }
    return a
}

private struct Boom: Error {}

// MARK: R1

final class BikeSaveConfirmationTests: XCTestCase {
    private func plan() throws -> BikeWorkoutPlan { try BikeWorkoutPlan.make(from: ride(), now: t0) }

    func testNilFinishThenFailingLookupIsUnconfirmedNotAPlainFailure() async throws {
        let p = try plan()
        var discarded = false
        do {
            try await BikeSaveConfirmation.run(plan: p, clearOrphans: {}, collect: {}, finish: { false }, discard: { discarded = true },
                                               lookup: { _ in throw Boom() })
            XCTFail("returned")
        } catch { XCTAssertEqual(error as? BikeImportError, .saveUnconfirmed(p.rideID)) }
        XCTAssertFalse(discarded, "the workout may exist; do not discard it")
    }

    func testNilFinishThenLookupFindingTheWorkoutIsSaved() async throws {
        let p = try plan()
        try await BikeSaveConfirmation.run(plan: p, clearOrphans: {}, collect: {}, finish: { false }, discard: {}, lookup: { _ in [p.syncIdentifier] })
    }

    func testNilFinishThenEmptyLookupIsUnconfirmed() async throws {
        let p = try plan()
        do {
            try await BikeSaveConfirmation.run(plan: p, clearOrphans: {}, collect: {}, finish: { false }, discard: {}, lookup: { _ in [] })
            XCTFail("returned")
        } catch { XCTAssertEqual(error as? BikeImportError, .saveUnconfirmed(p.rideID)) }
    }

    func testFinishReturningAWorkoutNeverQueries() async throws {
        let p = try plan()
        try await BikeSaveConfirmation.run(plan: p, clearOrphans: {}, collect: {}, finish: { true }, discard: {}, lookup: { _ in XCTFail("queried"); return [] })
    }

    /// A finish that throws may still have written the workout, so Health is asked; discard is not called after a finish.
    func testThrowingFinishThatWasWrittenIsSaved() async throws {
        let p = try plan()
        var discarded = false
        try await BikeSaveConfirmation.run(plan: p, clearOrphans: {}, collect: {}, finish: { throw Boom() }, discard: { discarded = true },
                                           lookup: { _ in [p.syncIdentifier] })
        XCTAssertFalse(discarded)
    }

    func testThrowingFinishNotFoundRethrowsTheOriginalErrorWithoutDiscarding() async throws {
        let p = try plan()
        var discarded = false
        do {
            try await BikeSaveConfirmation.run(plan: p, clearOrphans: {}, collect: {}, finish: { throw Boom() }, discard: { discarded = true }, lookup: { _ in [] })
            XCTFail("returned")
        } catch { XCTAssertTrue(error is Boom) }
        XCTAssertFalse(discarded)
    }

    func testThrowingFinishWithFailingLookupIsUnconfirmed() async throws {
        let p = try plan()
        do {
            try await BikeSaveConfirmation.run(plan: p, clearOrphans: {}, collect: {}, finish: { throw Boom() }, discard: {}, lookup: { _ in throw Boom() })
            XCTFail("returned")
        } catch { XCTAssertEqual(error as? BikeImportError, .saveUnconfirmed(p.rideID)) }
    }

    func testThrowingCollectionDiscardsAndRethrows() async throws {
        let p = try plan()
        var discarded = false
        do {
            try await BikeSaveConfirmation.run(plan: p, clearOrphans: {}, collect: { throw Boom() }, finish: { true }, discard: { discarded = true }, lookup: { _ in [] })
            XCTFail("returned")
        } catch { XCTAssertTrue(error is Boom) }
        XCTAssertTrue(discarded)
    }

    /// Audit H1: leftover samples from a failed or unconfirmed save are cleared BEFORE the ride's samples
    /// are added again, so a retry replaces them instead of doubling the day's energy and distance.
    func testOrphanSamplesAreClearedBeforeCollection() async throws {
        let p = try plan()
        var steps: [String] = []
        try await BikeSaveConfirmation.run(plan: p, clearOrphans: { steps.append("clear") },
                                           collect: { steps.append("collect") }, finish: { true },
                                           discard: {}, lookup: { _ in [] })
        XCTAssertEqual(steps, ["clear", "collect"])
    }

    /// If the leftovers cannot be cleared, nothing is written: the ride is retried next import rather than
    /// saved on top of samples that would double it.
    func testFailedOrphanClearingStopsTheSave() async throws {
        let p = try plan()
        var collected = false
        do {
            try await BikeSaveConfirmation.run(plan: p, clearOrphans: { throw Boom() },
                                               collect: { collected = true }, finish: { true },
                                               discard: {}, lookup: { _ in [] })
            XCTFail("returned")
        } catch { XCTAssertTrue(error is Boom) }
        XCTAssertFalse(collected)
    }
}

// MARK: R3 R4 R5 S1

final class BikeImporterRound2Tests: XCTestCase {
    func testOutOfRangeSampleTimeLandsInNotImportedNotFailed() async {
        let wild = BikeRide(summary: ride().summary, samples: [BikeRideSample(t: 1e30, cadence: 60, power: 100, speedMph: 10, hr: 0)])
        let r = await BikeImporter(api: api([wild]), store: FakeStore()).run()
        XCTAssertEqual(r.skipped.count, 1)
        XCTAssertTrue(r.failed.isEmpty)
        XCTAssertEqual(r.imported, 0)
    }

    func testRideDetailDecodeWithHugeTimeReachesTheImporterAsInvalid() throws {
        let json = "{\"summary\": {\"id\": \"20261102T172230Z\", \"elapsed\": 10, \"output_kj\": 1, \"calories\": 1, \"distance_mi\": 0.1}, \"samples\": [[1e30, 1, 1, null, 1, 0]]}"
        let decoded = try JSONDecoder().decode(BikeRide.self, from: Data(json.utf8))
        XCTAssertThrowsError(try BikeWorkoutPlan.make(from: decoded, now: t0))
    }

    func testBikeReadFailureDoesNotBlameHealth() async {
        let a = api([ride()]); a.rideError = NSError(domain: NSURLErrorDomain, code: -1009)
        let r = await BikeImporter(api: a, store: FakeStore()).run()
        XCTAssertEqual(r.failed.count, 1)
        let shown = r.failed[0].reason
        XCTAssertFalse(shown.contains("Health"), shown)
        XCTAssertFalse(shown.contains("unlocked"), shown)
    }

    func testListFailureAndCancellationDoNotBlameHealth() async {
        for err in [NSError(domain: "x", code: 1), CancellationError()] as [Error] {
            let a = FakeAPI(); a.list = .failure(err)
            let r = await BikeImporter(api: a, store: FakeStore()).run()
            let shown = r.error ?? ""
            XCTAssertFalse(shown.contains("unlocked"), shown)
            XCTAssertFalse(shown.contains("Health"), shown)
            XCTAssertFalse(shown.isEmpty)
        }
        XCTAssertFalse(BikeImporter.reason(for: CancellationError(), doing: "read the bike", kind: .bike).contains("unlocked"))
        XCTAssertTrue(BikeImporter.reason(for: Boom(), doing: "read the bike", kind: .bike).contains("Wi-Fi"))
        XCTAssertTrue(BikeImporter.reason(for: Boom(), doing: "save", kind: .health).contains("unlocked"))
    }

    func testHealthSaveFailureStillBlamesHealthAndIsPluralNeutral() async {
        let store = FakeStore(); store.rawError = NSError(domain: "com.apple.healthkit", code: 5)
        let r = await BikeImporter(api: api([ride()]), store: store).run()
        XCTAssertEqual(r.failed.count, 1)
        XCTAssertTrue(r.failed[0].reason.contains("Health could not"))
        XCTAssertFalse(r.failed[0].reason.contains("this ride"), r.failed[0].reason)
    }

    /// 250 permanently bad old rides must not hide a newer good one.
    func testBadOldRidesDoNotStarveANewerGoodRide() async {
        let base = BikeRideID.startDate(from: "20260301T000000Z")!
        let bad: [BikeRide] = (0..<250).map { i in
            let id = rideID(base.addingTimeInterval(TimeInterval(i * 600)))
            return BikeRide(summary: BikeRideSummary(id: id, elapsed: 10, outputKJ: 1, calories: 1, distanceMi: 0.1),
                            samples: [BikeRideSample(t: 0, cadence: 60, power: 1e9, speedMph: 10, hr: 0)])
        }
        let good = ride(id: "20261001T100000Z")
        let store = FakeStore()
        let r = await BikeImporter(api: api(bad + [good]), store: store).run()
        XCTAssertEqual(r.imported, 1)
        XCTAssertEqual(store.saved.first?.rideID, "20261001T100000Z")
        XCTAssertEqual(r.skipped.count, BikeLimits.maxRidesPerImport - 1)
        XCTAssertEqual(r.notes.filter { $0.rideID == nil }.count, 1)
    }

    func testBadRideIdNeverReachesTheScreen() async {
        let weird = "not-a-timestamp-\u{1F6B2}"
        let summary = BikeRideSummary(id: weird, elapsed: 10, outputKJ: 1, calories: 1, distanceMi: 0.1)
        let a = FakeAPI(); a.list = .success([summary])
        let r = await BikeImporter(api: a, store: FakeStore()).run()
        XCTAssertEqual(r.skipped.count, 1)
        XCTAssertEqual(r.skipped[0].reason, "The bike gave an id health4ai cannot read")
        XCTAssertFalse(r.skipped[0].reason.contains("not-a-timestamp"))
        XCTAssertEqual(BikeImportError.badRideID(weird).localizedDescription, r.skipped[0].reason)
        XCTAssertFalse(BikeClientError.badResponse("a ride id it cannot read").localizedDescription.contains(weird))
    }
}

// MARK: S2 S3 S4 and notes

final class BikeScreenTextTests: XCTestCase {
    private func stamp(_ d: Date) -> String { "D\(Int(d.timeIntervalSince1970))" }
    private func date(_ id: String) -> Date { BikeRideID.startDate(from: id)! }

    func testRunLevelIssuesAreNotCountedOrNamedAsRides() {
        let issues = [BikeIssue(rideID: nil, reason: "3 older rides were left for the next import"),
                      BikeIssue(rideID: "20261101T100000Z", reason: "a")]
        let s = BikeIssueSummary(issues, format: stamp)!
        XCTAssertEqual(s.count, 1)
        XCTAssertEqual(s.rides.count, 1)
        XCTAssertNil(BikeIssueSummary([BikeIssue(rideID: nil, reason: "only a run note")], format: stamp))
        XCTAssertEqual(BikeIssueSummary.runLevel(issues), ["3 older rides were left for the next import"])
    }

    func testNamedDatesBelongToTheHeadlineReasonOnly() {
        let issues = [BikeIssue(rideID: "20261101T100000Z", reason: "other"),
                      BikeIssue(rideID: "20261102T100000Z", reason: "common"),
                      BikeIssue(rideID: "20261103T100000Z", reason: "common"),
                      BikeIssue(rideID: "20261104T100000Z", reason: "common")]
        let s = BikeIssueSummary(issues, format: stamp)!
        XCTAssertEqual(s.reason, "common")
        XCTAssertEqual(s.reasonCount, 3)
        XCTAssertEqual(s.otherReasons, 1)
        XCTAssertEqual(s.rides, ["20261102T100000Z", "20261103T100000Z", "20261104T100000Z"].map { stamp(date($0)) })
        XCTAssertEqual(s.more, 0)
    }

    func testUnreadableDateIsListedLast() {
        let issues = [BikeIssue(rideID: "garbage", reason: "r"), BikeIssue(rideID: "20261101T100000Z", reason: "r")]
        let s = BikeIssueSummary(issues, format: stamp)!
        XCTAssertEqual(s.rides, [stamp(date("20261101T100000Z"))])
        XCTAssertEqual(s.detail, "\(stamp(date("20261101T100000Z"))), plus 1 ride with an unreadable date")
    }

    func testDeniedMessageDependsOnWhetherImportIsOn() {
        let on = BikeCopy.deniedMessage(missing: ["Cycling power"], isEnabled: true)
        let off = BikeCopy.deniedMessage(missing: ["Cycling power"], isEnabled: false)
        XCTAssertTrue(on.hasSuffix("Then come back here; the next import picks them up."))
        XCTAssertFalse(on.contains("switch import on again"))
        XCTAssertTrue(off.hasSuffix("Then switch import on again."))
        XCTAssertTrue(on.contains("Cycling power"))
    }

    func testRunErrorIsHiddenWhileAccessIsDenied() {
        var r = BikeImportResult(date: Date()); r.error = "Health write access is off for: Workouts."
        r.errorKind = .coreAccessMissing
        XCTAssertNil(BikeCopy.visibleError(r, denied: ["Workouts"]))
        XCTAssertEqual(BikeCopy.visibleError(r, denied: []), r.error)
        // A different error still shows, even while access is denied.
        var unreachable = BikeImportResult(date: Date()); unreachable.error = "Could not read the bike."
        XCTAssertEqual(BikeCopy.visibleError(unreachable, denied: ["Workouts"]), "Could not read the bike.")
    }

    func testImporterTagsOnlyTheMissingAccessErrorAsSuch() async {
        let denied = FakeStore(); denied.coreAccess = BikeCoreAccess(denied: ["Workouts"])
        let r = await BikeImporter(api: api([ride()]), store: denied).run()
        XCTAssertEqual(r.errorKind, .coreAccessMissing)
        let a = FakeAPI(); a.list = .failure(BikeClientError.timedOut(host: "x"))
        let r2 = await BikeImporter(api: a, store: FakeStore()).run()
        XCTAssertNotNil(r2.error)
        XCTAssertNil(r2.errorKind)
    }

    func testDatesInTheCurrentYearDropTheYear() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone.current
        let now = date("20261102T120000Z")
        let same = BikeCopy.rideDate(date("20261001T120000Z"), now: now, calendar: cal)
        let other = BikeCopy.rideDate(date("20250505T120000Z"), now: now, calendar: cal)
        XCTAssertFalse(same.contains("2026"), same)
        XCTAssertTrue(other.contains("2025"), other)
    }
}

// MARK: Audit H2: Erase Local Data turns the bike import off

@MainActor
final class BikeEraseTests: XCTestCase {
    func testEraseAllForgetsEveryBikeSettingAndSwitchesTheImportOff() {
        let suite = "bike-erase-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: BikeImportCoordinator.Keys.enabled)
        defaults.set("http://peloton-pi.local:8080", forKey: BikeImportCoordinator.Keys.url)
        defaults.set(Data("{}".utf8), forKey: BikeImportCoordinator.Keys.lastResult)
        defaults.set(["r1": "f"], forKey: DefaultsRejectedStore.keyPrefix + "rules")
        defaults.set("kept", forKey: "hkb.unrelated")

        let c = BikeImportCoordinator(defaults: defaults, store: FakeStore())
        XCTAssertTrue(c.isEnabled)
        c.eraseAll()

        XCTAssertFalse(c.isEnabled)
        XCTAssertEqual(c.urlText, "")
        XCTAssertNil(c.lastResult)
        XCTAssertTrue(defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("h4a.bike.") }.isEmpty)
        XCTAssertEqual(defaults.string(forKey: "hkb.unrelated"), "kept", "only bike keys are this method's to remove")
        XCTAssertFalse(BikeImportCoordinator(defaults: defaults, store: FakeStore()).isEnabled,
                       "a fresh launch after erase must not import")
    }
}

/// Runs a step (here: an erase) while the import is waiting on the bike, then answers like FakeAPI.
final class GatedAPI: BikeRideAPI {
    let inner = FakeAPI()
    var beforeList: () async -> Void = {}
    func listRides() async throws -> [BikeRideSummary] {
        await beforeList()
        return try await inner.listRides()
    }
    func ride(id: String) async throws -> BikeRide { try await inner.ride(id: id) }
}

@MainActor
final class BikeEraseDuringImportTests: XCTestCase {
    /// Review 2026-11-09: an import already running when the person erases must not write its result
    /// (or anything else under h4a.bike.) back afterwards.
    func testImportFinishingAfterEraseKeepsNothing() async {
        let suite = "bike-erase-race-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: BikeImportCoordinator.Keys.enabled)
        defaults.set("http://peloton-pi.local:8080", forKey: BikeImportCoordinator.Keys.url)

        let api = GatedAPI()
        let c = BikeImportCoordinator(defaults: defaults, store: FakeStore(), makeAPI: { _ in api })
        api.beforeList = { await MainActor.run { c.eraseAll() } }
        await c.importNow()

        XCTAssertNil(c.lastResult)
        XCTAssertFalse(c.isEnabled)
        XCTAssertTrue(defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("h4a.bike.") }.isEmpty)
    }

    /// Review 2026-11-09 (Codex recheck): after an erase, the import already running saves no more rides.
    func testEraseDuringImportStopsFurtherSaves() async {
        let suite = "bike-erase-stop-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: BikeImportCoordinator.Keys.enabled)
        defaults.set("http://peloton-pi.local:8080", forKey: BikeImportCoordinator.Keys.url)

        let api = GatedAPI()
        let r = ride()
        api.inner.list = .success([r.summary])
        api.inner.rides[r.summary.id] = r
        let store = FakeStore()
        let c = BikeImportCoordinator(defaults: defaults, store: store, makeAPI: { _ in api })
        api.beforeList = { await MainActor.run { c.eraseAll() } }
        await c.importNow()

        XCTAssertTrue(store.saved.isEmpty)
        XCTAssertTrue(api.inner.detailCalls.isEmpty, "a ride must not even be fetched after the erase")
    }

    /// Settings entered again after the erase, while the old import was still running, survive its end.
    func testImportFinishingAfterEraseKeepsSettingsEnteredSince() async {
        let suite = "bike-erase-reenter-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: BikeImportCoordinator.Keys.enabled)
        defaults.set("http://peloton-pi.local:8080", forKey: BikeImportCoordinator.Keys.url)

        let api = GatedAPI()
        let c = BikeImportCoordinator(defaults: defaults, store: FakeStore(), makeAPI: { _ in api })
        api.beforeList = {
            await MainActor.run {
                c.eraseAll()
                defaults.set("http://bike.local:8080", forKey: BikeImportCoordinator.Keys.url)
                defaults.set(["r1": "f"], forKey: DefaultsRejectedStore.keyPrefix + "rules")
            }
        }
        await c.importNow()

        XCTAssertEqual(defaults.string(forKey: BikeImportCoordinator.Keys.url), "http://bike.local:8080")
        XCTAssertNil(defaults.object(forKey: DefaultsRejectedStore.keyPrefix + "rules"))
        XCTAssertNil(c.lastResult)
    }
}

final class BikeImporterStopTests: XCTestCase {
    /// The stop check is asked before every ride, so an erase between two rides stops the second.
    func testStopCheckIsAskedBeforeEachRide() async {
        let a = ride(id: "20261102T172230Z"), b = ride(id: "20261101T172230Z")
        let api = FakeAPI()
        api.list = .success([a.summary, b.summary])
        api.rides = [a.summary.id: a, b.summary.id: b]
        let store = FakeStore()
        var importer = BikeImporter(api: api, store: store)
        var asked = 0
        importer.shouldContinue = { asked += 1; return asked <= 2 }   // ride a: before fetch, before save
        let result = await importer.run()
        XCTAssertEqual(store.saved.map(\.rideID), ["20261102T172230Z"])
        XCTAssertEqual(result.imported, 1)
        XCTAssertEqual(asked, 3)
    }

    /// An erase that lands while a ride is being fetched stops that ride before it is saved.
    func testStopCheckIsAskedAgainBeforeTheSave() async {
        let a = ride()
        let api = FakeAPI()
        api.list = .success([a.summary])
        api.rides = [a.summary.id: a]
        let store = FakeStore()
        var importer = BikeImporter(api: api, store: store)
        var asked = 0
        importer.shouldContinue = { asked += 1; return asked == 1 }   // erased during the fetch
        let result = await importer.run()
        XCTAssertEqual(api.detailCalls, [a.summary.id])
        XCTAssertTrue(store.saved.isEmpty)
        XCTAssertEqual(result.imported, 0)
    }
}
