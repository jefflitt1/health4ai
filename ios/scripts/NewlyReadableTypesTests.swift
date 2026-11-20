import Foundation

// Off-device tests for Health4AI/NewlyReadableTypes.swift. Run: ios/scripts/test_newly_readable_types.sh
// Expected values come from GitHub #71, not from the code: a metric switched on in Health
// after its import finished must get its history imported, a metric already imported with
// data must not be re-sent, and an upgrade must not re-send every metric's history.

var failures = 0
func check(_ ok: Bool, _ name: String) {
    print(ok ? "PASS \(name)" : "FAIL \(name)")
    if !ok { failures += 1 }
}

let rhr = "HKQuantityTypeIdentifierRestingHeartRate"
let hrv = "HKQuantityTypeIdentifierHeartRateVariabilitySDNN"
let swim = "HKQuantityTypeIdentifierDistanceSwimming"
let steps = "HKQuantityTypeIdentifierStepCount"

// The #71 sequence: only Resting HR was allowed when the import ran, so HRV finished empty.
// HRV is then switched on and now has samples. It must be re-armed.
var d = NewlyReadableTypes.decide(completed: [rhr, hrv, swim], seen: [rhr],
                                  trackingStarted: true, probed: [hrv])
check(d.rearm == [hrv], "switched_on_metric_is_rearmed")
check(!d.rearm.contains(rhr), "metric_imported_with_data_not_resent")
check(!d.rearm.contains(swim), "still_empty_metric_not_rearmed")
// Not recorded as seen until its re-armed sweep posts: an interrupted sweep must retry.
check(!d.seen.contains(hrv), "rearmed_metric_not_marked_seen_before_its_sweep")

// Candidates are finished types never seen with data; a seen type is never probed again.
check(NewlyReadableTypes.candidates(completed: [rhr, hrv, swim], seen: [rhr]) == [hrv, swim],
      "candidates_are_finished_and_unseen")
check(NewlyReadableTypes.candidates(completed: [hrv], seen: []) == [hrv],
      "finished_unseen_is_candidate")
check(NewlyReadableTypes.candidates(completed: [], seen: []).isEmpty,
      "unfinished_type_is_not_a_candidate")

// A probe can only re-arm a candidate: an unfinished type is the import's job, and a seen
// type already has its history.
d = NewlyReadableTypes.decide(completed: [hrv], seen: [rhr], trackingStarted: true,
                              probed: [rhr, steps, hrv])
check(d.rearm == [hrv], "probe_outside_candidates_ignored")

// Nothing found: nothing to do, seen unchanged.
d = NewlyReadableTypes.decide(completed: [hrv, swim], seen: [], trackingStarted: true, probed: [])
check(d.rearm.isEmpty && d.seen.isEmpty, "nothing_found_changes_nothing")

// Upgrade from a version without tracking: finished types with data cannot be told apart
// from ones switched on later, and re-arming them all would re-send every metric (hours).
// They are recorded as seen and nothing is re-armed.
d = NewlyReadableTypes.decide(completed: [rhr, steps, swim], seen: [],
                              trackingStarted: false, probed: [rhr, steps])
check(d.rearm.isEmpty, "upgrade_seeding_rearms_nothing")
check(d.seen == [rhr, steps], "upgrade_seeding_records_types_with_data")
// After seeding, a later switch-on is re-armed.
d = NewlyReadableTypes.decide(completed: [rhr, steps, swim], seen: d.seen,
                              trackingStarted: true, probed: [swim])
check(d.rearm == [swim], "after_seeding_new_switch_on_is_rearmed")

print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
