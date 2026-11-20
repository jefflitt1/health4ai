import Foundation

/// Which finished import types need their history imported again because HealthKit now
/// returns data it hid when they were swept (GitHub #71).
///
/// HealthKit never says whether a read type is authorized: a denied type answers every
/// query with nothing. So a type swept while denied finishes "complete" with zero samples,
/// and its live-sync anchor moves past the history it could not see. When the person later
/// turns the type on in the Health app, only samples newer than that anchor ever arrive,
/// and the years before it are never sent. That is how a Heart Rate Variability toggle
/// switched on after setup produced no history until a full re-import.
///
/// The only observable signal is the type itself: a finished type whose sweep posted
/// nothing that now has a sample inside the sweep window. `seen` is the set of types whose
/// import sweep posted at least one sample. Live sync never adds to it, because a single
/// new sample arriving after the grant is exactly the case that must still be re-armed.
///
/// Pure so it runs off-device (ios/scripts/test_newly_readable_types.sh).
enum NewlyReadableTypes {
    struct Decision: Equatable {
        /// Types to re-arm for a full sweep of the current window.
        var rearm: Set<String>
        /// The `seen` set to persist after this check.
        var seen: Set<String>
    }

    /// Types to probe: finished, and never seen with data.
    static func candidates(completed: Set<String>, seen: Set<String>) -> Set<String> {
        completed.subtracting(seen)
    }

    /// - Parameters:
    ///   - trackingStarted: false on the first check of an install that imported under a
    ///     version without this tracking (a separate marker, not the presence of `seen`,
    ///     because an import can record a type before that first check runs). Its finished types
    ///     with data were swept by code that never recorded them, so they cannot be told
    ///     apart from a type that was denied then. Re-arming all of them would re-send the
    ///     whole history (hours); they are recorded as seen instead, and only types that
    ///     become readable from here on are re-armed.
    ///   - probed: candidates for which HealthKit now returns at least one sample in the
    ///     current window. Candidates absent from it returned nothing.
    static func decide(completed: Set<String>,
                       seen: Set<String>,
                       trackingStarted: Bool,
                       probed: Set<String>) -> Decision {
        let found = probed.intersection(candidates(completed: completed, seen: seen))
        guard trackingStarted else {
            return Decision(rearm: [], seen: seen.union(found))
        }
        // Not marked seen here: the re-armed sweep records the type once it actually posts,
        // so an interrupted sweep leaves it unfinished (retried) rather than seen and lost.
        return Decision(rearm: found, seen: seen)
    }
}
