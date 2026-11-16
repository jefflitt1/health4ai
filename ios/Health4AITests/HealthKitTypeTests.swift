import HealthKit
import XCTest
@testable import Health4AI

// Sleep types requested in GitHub #44. Breathing disturbances is iOS 18+, so its unitMap key is
// a raw string literal; these tests pin that literal to the SDK symbol so a typo cannot ship.
final class HealthKitTypeTests: XCTestCase {
    func testSleepingWristTemperatureIsSyncedInCelsius() throws {
        let id = HKQuantityTypeIdentifier.appleSleepingWristTemperature
        let type = try XCTUnwrap(HKQuantityType.quantityType(forIdentifier: id))
        XCTAssertTrue(HealthKitManager.allSampleTypes().contains(type))
        XCTAssertEqual(HealthKitManager.unitMap[id.rawValue], .degreeCelsius())
    }

    func testSleepingBreathingDisturbancesIsSyncedAsCount() throws {
        guard #available(iOS 18.0, *) else { throw XCTSkip("type is iOS 18+") }
        let id = HKQuantityTypeIdentifier.appleSleepingBreathingDisturbances
        let type = try XCTUnwrap(HKQuantityType.quantityType(forIdentifier: id))
        XCTAssertTrue(HealthKitManager.allSampleTypes().contains(type))
        XCTAssertEqual(HealthKitManager.unitMap[id.rawValue], .count())
    }

    private func workout(events: [HKWorkoutEvent]?) -> HKWorkout {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        return HKWorkout(activityType: .running, start: start,
                         end: start.addingTimeInterval(600), workoutEvents: events,
                         totalEnergyBurned: nil, totalDistance: nil,
                         device: nil, metadata: nil)
    }

    func testWorkoutConversionPreservesRecordedEventsAndUUID() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let events = [
            HKWorkoutEvent(type: .lap, dateInterval: DateInterval(start: start, duration: 60), metadata: nil),
            HKWorkoutEvent(type: .pause, dateInterval: DateInterval(start: start.addingTimeInterval(60), duration: 0), metadata: nil),
            HKWorkoutEvent(type: .resume, dateInterval: DateInterval(start: start.addingTimeInterval(90), duration: 0), metadata: nil),
            HKWorkoutEvent(type: .segment, dateInterval: DateInterval(start: start.addingTimeInterval(90), duration: 120), metadata: nil)
        ]
        let source = workout(events: events)
        let sample = try XCTUnwrap(HealthKitManager.shared.convert(sample: source))
        let data = try JSONEncoder().encode(sample)
        let decoded = try JSONDecoder().decode(HealthSample.self, from: data)
        let roundTrip = try JSONEncoder().encode(decoded)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: roundTrip) as? NSDictionary,
                       try JSONSerialization.jsonObject(with: data) as? NSDictionary)
        let meta = try XCTUnwrap(sample.metadata)
        XCTAssertEqual(meta["workout_uuid"], .string(source.uuid.uuidString))
        XCTAssertEqual(meta["workout_events_total"], .int(4))
        XCTAssertEqual(meta["workout_events_truncated"], .bool(false))
        guard case .array(let exported) = meta["workout_events"] else { return XCTFail("events not structured") }
        XCTAssertEqual(exported.count, 4)
        guard case .object(let lap) = exported[0] else { return XCTFail("lap not structured") }
        XCTAssertEqual(lap["type"], .string("lap"))
        XCTAssertEqual(lap["duration_seconds"], .double(60))
        XCTAssertEqual(lap["started_at"], .string("2023-11-14T22:13:20.000Z"))
    }

    func testWorkoutEventsRespectRealIngestMetadataBudget() throws {
        let event = HKWorkoutEvent(type: .lap, dateInterval: DateInterval(start: Date(timeIntervalSince1970: 1_700_000_000), duration: 60), metadata: nil)
        let original: [String: AnyCodableValue] = ["existing": .string(String(repeating: "é", count: 500)),
                                                       "large_number": .double(1e20)]
        let meta = WorkoutExport.metadata(for: workout(events: Array(repeating: event, count: 100)), preserving: original)
        XCTAssertEqual(meta["existing"], original["existing"])
        XCTAssertEqual(meta["workout_events_total"], .int(100))
        XCTAssertEqual(meta["workout_events_truncated"], .bool(true))
        guard case .array(let exported) = meta["workout_events"] else { return XCTFail("missing events") }
        XCTAssertGreaterThan(exported.count, 0)
        XCTAssertLessThan(exported.count, 100)
        let encoded = try JSONEncoder().encode(meta)
        let json = try JSONSerialization.jsonObject(with: encoded)
        // Same UTF-8 serialized object byte count enforced by ingest's 4 KiB validator.
        let normalized = try JSONSerialization.data(withJSONObject: json, options: [.withoutEscapingSlashes])
        XCTAssertLessThanOrEqual(normalized.count, 4096)
    }

    func testBudgetAllowsForJavaScriptDecimalExpansion() throws {
        let event = HKWorkoutEvent(type: .lap, dateInterval: DateInterval(start: Date(timeIntervalSince1970: 1_700_000_000), duration: 60), metadata: nil)
        for length in 3000...3800 {
            let original: [String: AnyCodableValue] = ["padding": .string(String(repeating: "x", count: length)),
                                                       "large": .double(1e20)]
            let meta = WorkoutExport.metadata(for: workout(events: [event]), preserving: original)
            let data = try JSONEncoder().encode(meta)
            // Swift's 1e+20 becomes 100000000000000000000 in JSON.stringify.
            XCTAssertLessThanOrEqual(data.count + 16, 4096, "padding=\(length)")
        }
    }

    func testNearlyFullMetadataKeepsOriginalAndDoesNotClaimCompleteness() {
        let original: [String: AnyCodableValue] = ["existing": .string(String(repeating: "x", count: 4060))]
        let meta = WorkoutExport.metadata(for: workout(events: []), preserving: original)
        XCTAssertEqual(meta, original)
        XCTAssertNil(meta["workout_events_truncated"])
    }

    func testUnavailableEventsAreNotReportedAsCompleteEmptyList() {
        let meta = WorkoutExport.metadata(for: workout(events: nil), preserving: [:])
        XCTAssertEqual(meta["workout_events"], .null)
        XCTAssertEqual(meta["workout_events_total"], .null)
        XCTAssertEqual(meta["workout_events_truncated"], .null)
    }

    func testUnknownEventTypeRemainsRecognizable() {
        XCTAssertEqual(WorkoutExport.name(HKWorkoutEventType(rawValue: 999)!), "unknown")
    }
}
