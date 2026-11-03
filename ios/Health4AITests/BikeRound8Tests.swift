import XCTest
@testable import Health4AI

// Round 8: corrupt remembered data is reported, never silently dropped; stale keys are removed.

final class BikeRejectedStoreHealthTests: XCTestCase {
    private func suite(_ name: String) -> UserDefaults {
        let s = UserDefaults(suiteName: name)!
        s.removePersistentDomain(forName: name)
        return s
    }

    private final class Sink { var lines: [String] = [] }

    /// X1: every kind of corruption is reported (with the ride id where there is one); good entries survive.
    func testCorruptEntriesAreReportedAndGoodOnesSurvive() {
        let s = suite("bike-rejected-corrupt"); defer { s.removePersistentDomain(forName: "bike-rejected-corrupt") }
        let t = 1_790_000_000.0
        s.set([
            "good": ["f": "g", "t": t],
            "legacy": "fp",
            "noFingerprint": ["t": t],
            "oddShape": 5,
            "badDate": ["f": "s", "t": "soon"],
        ] as [String: Any], forKey: "h4a.bike.rejected.k1")
        let sink = Sink()
        let store = DefaultsRejectedStore(defaults: s, rulesKey: "k1", onProblem: { sink.lines.append($0) })
        let loaded = store.load()
        let now = Date(timeIntervalSince1970: t + 86_400)

        XCTAssertTrue(loaded["good"]?.holds(for: "g", now: now) == true, "a good entry survives")
        XCTAssertEqual(loaded["legacy"]?.holds(for: "fp", now: now), false, "legacy form counts as expired")
        XCTAssertNil(loaded["noFingerprint"], "no usable entry: the ride is fetched again")
        XCTAssertNil(loaded["oddShape"])
        XCTAssertEqual(loaded["badDate"]?.holds(for: "s", now: now), false, "an unreadable date is not trusted")

        XCTAssertEqual(sink.lines.count, 3, "\(sink.lines)")
        for id in ["noFingerprint", "oddShape", "badDate"] {
            XCTAssertTrue(sink.lines.contains { $0.contains(id) }, "no report names \(id): \(sink.lines)")
        }
        XCTAssertFalse(sink.lines.contains { $0.contains("good") || $0.contains("legacy") })
    }

    func testAValueThatIsNotADictionaryIsReported() {
        let s = suite("bike-rejected-notdict"); defer { s.removePersistentDomain(forName: "bike-rejected-notdict") }
        s.set("garbage", forKey: "h4a.bike.rejected.k1")
        let sink = Sink()
        let loaded = DefaultsRejectedStore(defaults: s, rulesKey: "k1", onProblem: { sink.lines.append($0) }).load()
        XCTAssertTrue(loaded.isEmpty)
        XCTAssertEqual(sink.lines.count, 1)
        XCTAssertTrue(sink.lines.first?.contains("not a dictionary") == true)
    }

    func testMissingDataIsNotAProblem() {
        let s = suite("bike-rejected-none"); defer { s.removePersistentDomain(forName: "bike-rejected-none") }
        let sink = Sink()
        XCTAssertTrue(DefaultsRejectedStore(defaults: s, rulesKey: "k1", onProblem: { sink.lines.append($0) }).load().isEmpty)
        XCTAssertTrue(sink.lines.isEmpty, "first run has nothing stored and nothing to report")
    }

    /// X2: sets stored under earlier rules keys are removed on save, and only those.
    func testSavingRemovesSetsStoredUnderOtherRulesKeys() {
        let s = suite("bike-rejected-orphans"); defer { s.removePersistentDomain(forName: "bike-rejected-orphans") }
        s.set(["a": "fp"], forKey: "h4a.bike.rejected.k1")
        s.set(["b": "fp"], forKey: "h4a.bike.rejected.v1")
        s.set("keep", forKey: "h4a.bike.unrelated")
        DefaultsRejectedStore(defaults: s, rulesKey: "k2").save(["c": BikeRejection(fingerprint: "x", at: Date())])
        XCTAssertNil(s.object(forKey: "h4a.bike.rejected.k1"), "an old key must not live forever")
        XCTAssertNil(s.object(forKey: "h4a.bike.rejected.v1"))
        XCTAssertNotNil(s.object(forKey: "h4a.bike.rejected.k2"))
        XCTAssertEqual(s.string(forKey: "h4a.bike.unrelated"), "keep", "only rejection keys are touched")
        XCTAssertEqual(DefaultsRejectedStore(defaults: s, rulesKey: "k2").load().count, 1)
    }
}
