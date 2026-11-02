import XCTest
@testable import Health4AI

// Round 5: what the Bike screen says (design gate findings V1 to V3 and notes).

final class BikeGateRound5Tests: XCTestCase {
    private func stamp(_ d: Date) -> String { "D\(Int(d.timeIntervalSince1970))" }

    /// V1: three rides with unreadable dates give one phrase, never three.
    func testUnreadableDatesAreCountedOnceNotListed() {
        let issues = ["x1", "x2", "x3", "20261101T100000Z"].map { BikeIssue(rideID: $0, reason: "r") }
        let s = BikeIssueSummary(issues, format: stamp)!
        XCTAssertEqual(s.rides.count, 1, "only the dated ride is named")
        XCTAssertEqual(s.rides.filter { $0.contains("unreadable") }.count, 0)
        XCTAssertEqual(s.unreadablePhrase, "3 rides with unreadable dates")
        XCTAssertEqual(s.detail?.components(separatedBy: "unreadable").count, 2, "the word appears exactly once")
        XCTAssertTrue(s.detail?.hasSuffix("plus 3 rides with unreadable dates") == true, s.detail ?? "nil")
    }

    func testOneUnreadableDateIsSingular() {
        let s = BikeIssueSummary([BikeIssue(rideID: "x1", reason: "r"), BikeIssue(rideID: "20261101T100000Z", reason: "r")], format: stamp)!
        XCTAssertEqual(s.unreadablePhrase, "1 ride with an unreadable date")
    }

    /// V1: when every ride in the row is unreadable there is no "For this reason:" line at all.
    func testAllUnreadableDropsTheDetailLine() {
        let s = BikeIssueSummary(["x1", "x2", "x3"].map { BikeIssue(rideID: $0, reason: "r") }, format: stamp)!
        XCTAssertTrue(s.allUnreadable)
        XCTAssertNil(s.detail)
    }

    /// N2: a mixed row whose headline reason is the unreadable-id one has no detail line either.
    func testMixedRowWithAnUnreadableHeadlineReasonDropsTheDetailLine() {
        let issues = ["x1", "x2", "x3"].map { BikeIssue(rideID: $0, reason: "unreadable id") }
            + [BikeIssue(rideID: "20261101T100000Z", reason: "other")]
        let s = BikeIssueSummary(issues, format: stamp)!
        XCTAssertEqual(s.reason, "unreadable id")
        XCTAssertEqual(s.otherReasons, 1)
        XCTAssertTrue(s.allUnreadable)
        XCTAssertNil(s.detail)
    }

    /// N1: one wording for the heart-rate promise, in the footer and in the per-ride note.
    func testHeartRateWordingIsOneConstant() throws {
        XCTAssertEqual(BikeCopy.heartRateCannotBeAddedLater, "A ride imported without heart rate cannot get it added later.")
        let path = #filePath.replacingOccurrences(of: "Health4AITests/BikeRound5Tests.swift", with: "Health4AI/BikeImport/BikeImportView.swift")
        let source = try String(contentsOfFile: path, encoding: .utf8)   // throws, so this can never pass vacuously
        XCTAssertTrue(source.contains("\\(BikeCopy.heartRateCannotBeAddedLater)"), "the footer must use the shared constant")
        XCTAssertFalse(source.contains("will not get it later"))
    }

    func testMoreThanThreeDatedRidesStillCountsOverflow() {
        let ids = (1...5).map { "2026110\($0)T100000Z" }
        let s = BikeIssueSummary(ids.map { BikeIssue(rideID: $0, reason: "r") } + [BikeIssue(rideID: "zz", reason: "other")], format: stamp)!
        XCTAssertEqual(s.rides.count, 3)
        XCTAssertEqual(s.more, 2)
        XCTAssertTrue(s.detail?.hasPrefix("For this reason: ") == true)
        XCTAssertTrue(s.detail?.contains("and 2 more") == true)
    }

    /// V2: a denied-while-enabled result never leaves "Last import" with only a timestamp.
    func testDeniedLastImportHasItsOwnLine() {
        var r = BikeImportResult(date: Date())
        r.error = "Health write access is off for: Cycling power."
        r.errorKind = .coreAccessMissing
        XCTAssertNil(BikeCopy.visibleError(r, denied: ["Cycling power"]))
        XCTAssertEqual(BikeCopy.errorLine(r, denied: ["Cycling power"]), "No rides imported. Health access is off (see above).")
        XCTAssertEqual(BikeCopy.deniedLastImport, "No rides imported. Health access is off (see above).")
        // Any other error still speaks for itself.
        var other = BikeImportResult(date: Date()); other.error = "Could not read the bike."
        XCTAssertEqual(BikeCopy.errorLine(other, denied: ["Cycling power"]), "Could not read the bike.")
    }

    /// Notes: per-ride reasons read right for one ride or many, and each starts with a capital.
    func testReasonsArePluralNeutralAndCapitalised() {
        let reasons = [BikeImportError.noSamples, .badRideID("x"), .invalidRide("power is high"), .invalidDate("old"), .saveUnconfirmed("x")]
            .map { $0.localizedDescription }
        for text in reasons {
            XCTAssertFalse(text.contains("this ride"), text)
            XCTAssertTrue(text.first?.isUppercase == true, text)
        }
    }
}
