import Foundation
import os

/// The finish-and-confirm logic of a save, separated from HealthKit so tests can drive it.
///
/// `finishWorkout()` can return nil without an error (for example while the phone is locked), and it can
/// also THROW after the workout was in fact written. Either way the only trustworthy answer is Health
/// itself, so after any finish that does not return a workout, ask Health by sync identifier:
///   found                      -> saved (a thrown finish error is then moot)
///   not found, finish threw    -> the original error, a plain failure
///   not found, finish was nil  -> `saveUnconfirmed` (outcome unknown, re-checked next import)
///   the lookup itself throws   -> `saveUnconfirmed` (a locked phone fails that query too)
///
/// `discardWorkout()` is called only when collection fails. Apple's header describes it as an alternative
/// to finishing ("Finishes building the workout and discards the result instead of saving it"); it does not
/// say it is valid after `finishWorkout` has been attempted, so it is not called then. Note the header also
/// says samples already added are not deleted by a discard.
enum BikeSaveConfirmation {
    private static let logger = Logger(subsystem: "com.jglittell.health4ai", category: "BikeImport")

    /// - collect: everything up to and including ending collection. A throw here discards the workout.
    /// - finish: `finishWorkout()`; true when it returned a workout.
    /// - discard: `discardWorkout()`.
    /// - lookup: the sync-identifier query.
    static func run(plan: BikeWorkoutPlan,
                    collect: () async throws -> Void,
                    finish: () async throws -> Bool,
                    discard: () -> Void,
                    lookup: ([String]) async throws -> Set<String>) async throws {
        do { try await collect() } catch {
            discard()
            throw error
        }
        var finishError: Error?
        do { if try await finish() { return } } catch { finishError = error }
        let found: Set<String>
        do { found = try await lookup([plan.syncIdentifier]) } catch {
            logger.error("could not re-check ride \(plan.rideID, privacy: .public) after an unfinished save: \(String(describing: error), privacy: .public)")
            throw BikeImportError.saveUnconfirmed(plan.rideID)
        }
        if found.contains(plan.syncIdentifier) { return }
        if let finishError { throw finishError }
        throw BikeImportError.saveUnconfirmed(plan.rideID)
    }
}
