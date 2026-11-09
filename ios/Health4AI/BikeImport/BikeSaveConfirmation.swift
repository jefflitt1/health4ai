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
///
/// Because of that, a ride whose earlier save failed or went unconfirmed can leave its energy, distance,
/// power, cadence and heart rate samples in Health with no workout. The importer only re-saves a ride whose
/// workout Health does not have, so before collecting, `clearOrphans` deletes this app's bike samples in the
/// ride's window. Without it the retry adds every sample a second time and the day's totals double (audit
/// H1, 2026-11-05). If it throws, nothing is collected: a skipped ride is retried, a doubled one is not undone.
enum BikeSaveConfirmation {
    private static let logger = Logger(subsystem: "com.jglittell.health4ai", category: "BikeImport")

    /// - clearOrphans: deletes this app's leftover samples for the ride. A throw stops the save.
    /// - collect: everything up to and including ending collection. A throw here discards the workout.
    /// - finish: `finishWorkout()`; true when it returned a workout.
    /// - discard: `discardWorkout()`.
    /// - lookup: the sync-identifier query.
    static func run(plan: BikeWorkoutPlan,
                    clearOrphans: () async throws -> Void,
                    collect: () async throws -> Void,
                    finish: () async throws -> Bool,
                    discard: () -> Void,
                    lookup: ([String]) async throws -> Set<String>) async throws {
        try await clearOrphans()
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
