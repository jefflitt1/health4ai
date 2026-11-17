import HealthKit
import CoreLocation

enum WorkoutRouteReader {
    static func requestPermission() async throws {
        // Only called from the separate user-operated route switch.
        try await HealthKitManager.shared.store.requestAuthorization(toShare: [], read: [HKSeriesType.workoutRoute()])
    }

    static func routes(workout: HKWorkout) async throws -> [HKWorkoutRoute] {
        try await WorkoutHealthQuery<[HKWorkoutRoute]>().run { complete in
            HKSampleQuery(sampleType: HKSeriesType.workoutRoute(),
                predicate: HKQuery.predicateForObjects(from: workout), limit: 33, sortDescriptors: nil) { _, samples, error in
                if let error { complete(.failure(error)); return }
                let routes = (samples ?? []).compactMap { $0 as? HKWorkoutRoute }
                guard routes.count <= 32, routes.reduce(0, { $0 + $1.count }) <= 100_000 else {
                    complete(.failure(WorkoutDetailError.limit)); return
                }
                complete(.success(routes))
            }
        }
    }

    static func observation(_ route: HKWorkoutRoute) async throws -> WorkoutRouteObservation {
        let state = RouteQueryState(route: route)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in state.start(continuation) }
        } onCancel: { state.cancel() }
    }
}

/// HealthKit callbacks and cancellation may run concurrently. Serialize completion
/// so cancellation stops the query and resumes its awaiting task exactly once.
private final class RouteQueryState: @unchecked Sendable {
    private let lock = NSLock()
    private let route: HKWorkoutRoute
    private let collector: WorkoutRouteCollector
    private var query: HKWorkoutRouteQuery?
    private var continuation: CheckedContinuation<WorkoutRouteObservation, Error>?
    private var finished = false

    init(route: HKWorkoutRoute) {
        self.route = route
        collector = WorkoutRouteCollector(routeID: route.uuid, expected: route.count)
    }

    func start(_ continuation: CheckedContinuation<WorkoutRouteObservation, Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
        self.continuation = continuation
        let query = HKWorkoutRouteQuery(route: route) { [weak self] _, locations, done, error in
            self?.receive(locations: locations, done: done, error: error)
        }
        self.query = query
        // Execute under the lock so cancellation cannot stop before execution begins.
        HealthKitManager.shared.store.execute(query)
        lock.unlock()
    }

    func cancel() { complete(.failure(CancellationError())) }

    private func receive(locations: [CLLocation]?, done: Bool, error: Error?) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        let result: Result<WorkoutRouteObservation, Error>?
        do {
            if let error { throw error }
            guard let locations else { throw WorkoutDetailError.invalidResponse }
            result = try collector.append(locations, done: done).map { .success($0) }
        } catch { result = .failure(error) }
        lock.unlock()
        if let result { complete(result) }
    }

    private func complete(_ result: Result<WorkoutRouteObservation, Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        let query = self.query
        self.query = nil
        lock.unlock()
        if let query { HealthKitManager.shared.store.stop(query) }
        continuation?.resume(with: result)
    }
}
