import HealthKit
import XCTest
@testable import Health4AI

@MainActor
final class WorkoutQueryTests: XCTestCase {
    func testCancelStopsQueryAndIgnoresLateCallback() async throws {
        var completion: WorkoutHealthQuery<Int>.Completion?
        var executed = 0, stopped = 0
        let started = expectation(description: "Query registered")
        let bridge = WorkoutHealthQuery<Int>(execute: { _ in executed += 1; started.fulfill() }, stop: { _ in stopped += 1 })
        let task = Task {
            try await bridge.run { callback in
                completion = callback
                return HKSampleQuery(sampleType: .workoutType(), predicate: nil, limit: 1, sortDescriptors: nil) { _, _, _ in }
            }
        }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertEqual(executed, 1)
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancellation should throw") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(stopped, 1)
        completion?(.success(42))
        XCTAssertEqual(stopped, 1)
    }

    func testCompletedQueryReturnsActualValueAndStopsOnce() async throws {
        var completion: WorkoutHealthQuery<Int>.Completion?
        var stopped = 0
        let started = expectation(description: "Query registered")
        let bridge = WorkoutHealthQuery<Int>(execute: { _ in started.fulfill() }, stop: { _ in stopped += 1 })
        let task = Task {
            try await bridge.run { callback in
                completion = callback
                return HKSampleQuery(sampleType: .workoutType(), predicate: nil, limit: 1, sortDescriptors: nil) { _, _, _ in }
            }
        }
        await fulfillment(of: [started], timeout: 2)
        completion?(.success(7))
        let value = try await task.value
        XCTAssertEqual(value, 7)
        task.cancel()
        XCTAssertEqual(stopped, 1)
    }
}
