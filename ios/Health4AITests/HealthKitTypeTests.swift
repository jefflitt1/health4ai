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
}
