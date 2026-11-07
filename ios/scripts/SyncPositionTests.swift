import Foundation

// Off-device tests for Health4AI/SyncPosition.swift. Run: ios/scripts/test_sync_position.sh
// Expected values come from the rule the app needs, not from the code: the HealthKit anchors
// belong to one database, a different database must get the whole history, and the same
// database must not be sent its history again.

var failures = 0
func check(_ ok: Bool, _ name: String) {
    print(ok ? "PASS \(name)" : "FAIL \(name)")
    if !ok { failures += 1 }
}

let supabase = "https://abcd.supabase.co/functions/v1/healthkit-ingest"
let otherSupabase = "https://wxyz.supabase.co/functions/v1/healthkit-ingest"
let siteA = "https://site-a.netlify.app/api/ingest"
let siteB = "https://site-b.netlify.app/api/ingest"

// An install from before the record: its anchors were built against Supabase.
check(!SyncPosition.needsReset(recorded: nil, connecting: supabase, connectingIsSupabase: true),
      "unrecorded_then_supabase_keeps_position")
check(SyncPosition.needsReset(recorded: nil, connecting: siteA, connectingIsSupabase: false),
      "unrecorded_then_netlify_restarts")

// Signing in again to the same database (after a sign-out, or a Sheets detour) keeps it.
check(!SyncPosition.needsReset(recorded: supabase, connecting: supabase, connectingIsSupabase: true),
      "same_supabase_keeps_position")
check(!SyncPosition.needsReset(recorded: siteA, connecting: siteA, connectingIsSupabase: false),
      "same_site_keeps_position")

// A different database restarts it, whichever kind it is.
check(SyncPosition.needsReset(recorded: supabase, connecting: siteA, connectingIsSupabase: false),
      "supabase_then_netlify_restarts")
check(SyncPosition.needsReset(recorded: siteA, connecting: supabase, connectingIsSupabase: true),
      "netlify_then_supabase_restarts")
check(SyncPosition.needsReset(recorded: siteA, connecting: siteB, connectingIsSupabase: false),
      "site_a_then_site_b_restarts")
check(SyncPosition.needsReset(recorded: supabase, connecting: otherSupabase, connectingIsSupabase: true),
      "other_supabase_project_restarts")

// Spelling the same address differently is not a different database.
check(!SyncPosition.needsReset(recorded: siteA, connecting: "https://Site-A.netlify.app/api/ingest", connectingIsSupabase: false),
      "host_case_ignored")
check(!SyncPosition.needsReset(recorded: siteA, connecting: siteA + "/", connectingIsSupabase: false),
      "trailing_slash_ignored")
check(!SyncPosition.needsReset(recorded: siteA, connecting: " " + siteA + "\n", connectingIsSupabase: false),
      "surrounding_whitespace_ignored")

print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
