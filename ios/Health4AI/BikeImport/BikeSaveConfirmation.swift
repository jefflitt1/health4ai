import Foundation
import os

/// The finish-and-confirm logic of a save, separated from HealthKit so tests can drive it.
///
/// `finishWorkout()` can return nil without an error (for example while the phone is locked) even though
/// the workout may have been written. So: if it returns nil, ask Health. If Health shows the workout, it
/// is saved. If Health does not, or the question itself cannot be answered (a locked phone makes that
/// query fail too), the outcome is UNKNOWN: throw `saveUnconfirmed`, never a plain failure, so the
/// ride is re-checked on the next import instead of being reported as failed.
enum BikeSaveConfirmation {
    private static let logger = Logger(subsystem: "com.jglittell.health4ai", category: "BikeImport")

    /// - collect: everything up to and including ending collection. A throw here discards the workout.
    /// - finish: `finishWorkout()`; true when it returned a workout. A throw here also discards.
    /// - discard: `discardWorkout()`.
    /// - lookup: the sync-identifier query.
    static func run(plan: BikeWorkoutPlan,
                    collect: () async throws -> Void,
                    finish: () async throws -> Bool,
                    discard: () -> Void,
                    lookup: ([String]) async throws -> Set<String>) async throws {
        let finished: Bool
        do {
            try await collect()
            finished = try await finish()
        } catch {
            discard()
            throw error
        }
        guard !finished else { return }
        let found: Set<String>
        do { found = try await lookup([plan.syncIdentifier]) } catch {
            logger.error("could not re-check ride \(plan.rideID, privacy: .public) after a nil finish: \(String(describing: error), privacy: .public)")
            throw BikeImportError.saveUnconfirmed(plan.rideID)
        }
        guard found.contains(plan.syncIdentifier) else { throw BikeImportError.saveUnconfirmed(plan.rideID) }
    }
}
