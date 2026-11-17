import HealthKit

/// Bridges one-result HealthKit queries with cancellation. A pending HealthKit
/// callback must not hold the export UI busy after the user cancels or signs out.
final class WorkoutHealthQuery<Value>: @unchecked Sendable {
    typealias Completion = (Result<Value, Error>) -> Void
    private let lock = NSLock()
    private let execute: (HKQuery) -> Void
    private let stop: (HKQuery) -> Void
    private var query: HKQuery?
    private var continuation: CheckedContinuation<Value, Error>?
    private var finished = false

    init(execute: @escaping (HKQuery) -> Void = { HealthKitManager.shared.store.execute($0) },
         stop: @escaping (HKQuery) -> Void = { HealthKitManager.shared.store.stop($0) }) {
        self.execute = execute
        self.stop = stop
    }

    func run(make: @escaping (@escaping Completion) -> HKQuery) async throws -> Value {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                guard !finished else { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
                self.continuation = continuation
                let query = make { [weak self] in self?.complete($0) }
                self.query = query
                // HealthKit execution is asynchronous. Register under the same lock
                // so cancellation cannot stop a query before it has been started.
                execute(query)
                lock.unlock()
            }
        } onCancel: { self.complete(.failure(CancellationError())) }
    }

    private func complete(_ result: Result<Value, Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let query = self.query
        let continuation = self.continuation
        self.query = nil
        self.continuation = nil
        lock.unlock()
        if let query { stop(query) }
        continuation?.resume(with: result)
    }
}
