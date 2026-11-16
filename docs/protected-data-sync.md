# Protected Health data deferral

Draft fix, 2026-11-15. Not deployed or verified on a physical device.

## Evidence

The installed 1.0.6 build 74 recorded two launch-triggered failures on November 14,
02:38:02Z and 04:26:15Z: all 174 types failed with “Protected health data is
inaccessible.” AppDelegate reconnect started a full pass on background launch
without checking protected data availability. The device was locked when inspected.
Apple defines HKError.errorDatabaseInaccessible as the locked-device condition.

## Behavior

- Launch setup, full sync, and history import defer while protected data is unavailable.
- The exact HealthKit error domain/code handles a lock that races the initial check.
  Permission, network, authentication, and other errors retain existing error behavior.
- Full sync stops scanning further types when HealthKit becomes inaccessible. Any
  real failures preceding the lock remain failures rather than being hidden.
- Deferred work has separate launch/sync/history markers. Unlock and foreground
  transitions retry it. A normal sync does not clear a pending history marker.
- Sign-out, erase and destination changes clear deferred markers and invalidate old
  callback generations. Deferred writes/removals from already-running earlier work
  are ignored. Newly starting sync/import work also requires authentication, and
  Sheets never accepts a database-history deferral.
- Deferral does not stamp last sync success, invent zero-record success, advance an
  unposted anchor, or mark history complete. Already-posted checkpoints are retained.
- Background completion is unsuccessful when the work was deferred.
- Home says “Waiting for device unlock” when connected and deferred; existing actual
  sync errors retain higher priority. No Health permission or default setting changes.

## Verification and release gates

- Six native helper checks exercise exact error classification, text-only nonmatches,
  unrelated HealthKit errors, and injected availability.
- AppLifecycleTests adds real runFullPass preflight, untouched timestamp/anchor,
  unlock routing, and mixed-error scan tests. Tests compile in Xcode.
- iOS XCTest execution and physical locked/unlocked foreground behavior remain
  unverified because this Mac's simulator cannot boot (launchd_sim session failure).
- Independent code/security/silent-failure and Sasha UI review required before merge.
- Do not close D1200 until the physical device no longer logs all-type failure while
  locked and an unlocked retry actually syncs data.

## Applicable rules

- ~/AGENTS.md:40 — run verification and retain unverified runtime checks explicitly.
- ~/AGENTS.md:53 — isolated worktree; main checkout unchanged.
- ~/AGENTS.md:61 — no production DB used in tests.
- ~/AGENTS.md:70 — typed root-cause handling, never a generic swallowed error.
- ~/claude-agents/docs/operations/compound-practices.md:34 — inspect changed code
  after initial successful build; only indentation/comment simplification applied.

Apple reference: https://developer.apple.com/documentation/healthkit/hkerror/code/errordatabaseinaccessible
