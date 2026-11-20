import Foundation

// Off-device tests for Health4AI/NewlyReadableTypes.swift. Run: ios/scripts/test_newly_readable_types.sh
// Expected values come from GitHub #71, not from the code: a metric switched on in Health
// after its import finished must get its history imported, a metric already imported with
// data must not be re-sent, an upgrade must not re-send every metric's history, and no
// metric may be re-sent over and over.

var failures = 0
func check(_ ok: Bool, _ name: String) {
    print(ok ? "PASS \(name)" : "FAIL \(name)")
    if !ok { failures += 1 }
}

let rhr = "HKQuantityTypeIdentifierRestingHeartRate"
let hrv = "HKQuantityTypeIdentifierHeartRateVariabilitySDNN"
let swim = "HKQuantityTypeIdentifierDistanceSwimming"
let steps = "HKQuantityTypeIdentifierStepCount"

func decide(completed: Set<String>, seen: Set<String> = [], rearmed: Set<String> = [],
            tracking: Bool = true, probed: Set<String>, failed: Bool = false)
    -> NewlyReadableTypes.Decision {
    NewlyReadableTypes.decide(completed: completed, seen: seen, rearmed: rearmed,
                              trackingStarted: tracking, probed: probed, probeFailed: failed)
}

// The #71 sequence: only Resting HR was allowed when the import ran, so HRV finished empty.
// HRV is then switched on and now has samples. It must be re-armed.
var d = decide(completed: [rhr, hrv, swim], seen: [rhr], probed: [hrv])
check(d.rearm == [hrv], "switched_on_metric_is_rearmed")
check(!d.rearm.contains(rhr), "metric_imported_with_data_not_resent")
check(!d.rearm.contains(swim), "still_empty_metric_not_rearmed")
// Not recorded as seen until its re-armed sweep posts: an interrupted sweep must retry.
check(!d.seen.contains(hrv), "rearmed_metric_not_marked_seen_before_its_sweep")
check(d.rearmed.contains(hrv), "rearm_is_recorded")
check(d.trackingStarted, "tracking_stays_started")

// A re-armed type whose sweep still posted nothing (every sample filtered, or a resume
// over empty chunks) is not re-armed again: that would re-send it on every pass.
d = decide(completed: [hrv], seen: [], rearmed: [hrv], probed: [hrv])
check(d.rearm.isEmpty, "rearmed_once_is_never_rearmed_again")

// Candidates are finished types never seen with data and never re-armed.
check(NewlyReadableTypes.candidates(completed: [rhr, hrv, swim], seen: [rhr], rearmed: []) == [hrv, swim],
      "candidates_are_finished_and_unseen")
check(NewlyReadableTypes.candidates(completed: [hrv, swim], seen: [], rearmed: [swim]) == [hrv],
      "rearmed_type_is_not_a_candidate")
check(NewlyReadableTypes.candidates(completed: [], seen: [], rearmed: []).isEmpty,
      "unfinished_type_is_not_a_candidate")

// A probe can only re-arm a candidate.
d = decide(completed: [hrv], seen: [rhr], probed: [rhr, steps, hrv])
check(d.rearm == [hrv], "probe_outside_candidates_ignored")

// Nothing found: nothing to do.
d = decide(completed: [hrv, swim], probed: [])
check(d.rearm.isEmpty && d.seen.isEmpty && d.rearmed.isEmpty, "nothing_found_changes_nothing")

// Upgrade from a version without tracking: finished types with data cannot be told apart
// from ones switched on later, and re-arming them all would re-send every metric (hours).
d = decide(completed: [rhr, steps, swim], tracking: false, probed: [rhr, steps])
check(d.rearm.isEmpty, "upgrade_seeding_rearms_nothing")
check(d.seen == [rhr, steps], "upgrade_seeding_records_types_with_data")
check(d.trackingStarted, "clean_seeding_starts_tracking")
// After seeding, a later switch-on is re-armed.
d = decide(completed: [rhr, steps, swim], seen: d.seen, probed: [swim])
check(d.rearm == [swim], "after_seeding_new_switch_on_is_rearmed")

// A probe that failed during seeding leaves seeding open, so that type is seeded on the
// next check instead of being re-armed (and re-sent) as newly readable.
d = decide(completed: [rhr, steps], tracking: false, probed: [rhr], failed: true)
check(d.rearm.isEmpty, "failed_seeding_rearms_nothing")
check(!d.trackingStarted, "failed_seeding_keeps_seeding_open")
d = decide(completed: [rhr, steps], seen: d.seen, tracking: d.trackingStarted, probed: [steps])
check(d.rearm.isEmpty && d.seen == [rhr, steps], "next_seeding_records_the_failed_type")

print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
