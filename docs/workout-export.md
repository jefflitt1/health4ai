# Workout event export

This extension preserves workout identity and recorded events in the existing
Supabase workout row's `metadata`. It does not change the database schema or
request additional HealthKit permissions. Data goes to the user's configured
backend; health4ai does not receive it.

## Fields

- `workout_uuid`: the UUID of the source HealthKit workout.
- `workout_events`: ordered array of events returned by HealthKit. Each event has
  `type`, numeric `type_raw`, UTC `started_at` and `ended_at` with milliseconds,
  and `duration_seconds`.
- `workout_events_total`: number of events returned by HealthKit.
- `workout_events_truncated`: whether the exported array is only a prefix.

Types include lap, segment, marker, pause, resume, motion pause/resume, and
pause/resume request. Unknown types keep their numeric value. Events are recorded
markers, not synthesized mile/kilometer splits. A pause/resume *request* is not
proof that a pause/resume occurred.

The ingest endpoint permits at most 4 KiB of serialized metadata. Existing metadata
is preserved and only as many events as fit are added. Inspect the total and
truncation flag before interpreting the sequence as complete. If even the new
header fields do not fit, enrichment is omitted with a device log warning, leaving
the original payload unchanged. No completeness fields then means unknown.

When HealthKit supplies no event array, event fields are null, not a claim of zero
events. Older exported rows also have unknown completeness. Existing rows are not
automatically re-exported by this change; use a deliberate history export to
refresh them after installing a build containing the change.

The MCP `get_workouts` tool exposes `workout_uuid`, `events`, `events_total`, and
`events_truncated`. Raw metric access also retains the metadata.

## Remaining scope of GitHub #54

GPS routes, exact sample-to-workout associations, cadence derivation, and FIT
files are not included. Routes need a separate optional read permission and a
bounded storage/pagination design, not a large metadata blob. Time overlap alone
must not be presented as an exact HealthKit association. Running dynamics already
sync as separate quantity samples when the user enables those Health types.

Apple's event semantics:
https://developer.apple.com/documentation/healthkit/hkworkoutevent

## Verification

Verified 2026-11-16: eight HealthKitTypeTests pass on the iOS 27 simulator,
including actual HKWorkout conversion, JSON round trip, unavailable events and
the 801-length numeric-budget sweep. The first runtime pass exposed two invalid
fixtures whose events were dated outside the fixed workout interval; aligning
those dates changed the result from two failures to zero. Production code unchanged.

Run `xcodebuild test -project ios/Health4AI.xcodeproj -scheme Health4AI
-destination 'platform=iOS Simulator,id=<simulator UUID>'
-only-testing:Health4AITests/HealthKitTypeTests -parallel-testing-enabled NO`.
Use normal simulator signing; unsigned test artifacts built but stalled at launch.
The full iOS XCTest suite also passed: 114 tests, zero failures.
Physical-device recorded-workout export remains a release acceptance check.
