# Workout detail wire v1 (disabled by default)

POST the same configured Supabase project's `/functions/v1/workout-details`.
Authorization: the existing user's Bearer JWT. No service key belongs on the phone.
The function requires `HEALTH4AI_WORKOUT_DETAILS_ENABLED=true`; otherwise 404 with
`{"error":"feature_disabled","capabilities":[]}`. No ordinary ingest behavior changes.

All bodies are JSON objects with exactly the keys specified below. UUID strings
use the standard hyphenated form. UTC timestamps accept `YYYY-MM-DDTHH:mm:ssZ` or
1–3 fractional digits before Z. Values must be finite JSON numbers. No metadata,
coordinates, client user ID, cadence estimates or extra fields are accepted.

| Operation | Request keys in addition to operation | Successful response |
|---|---|---|
| capabilities | none | `{capabilities:["workout_details_v1"]}` |
| begin | workout_uuid, export_uuid, query_types | `{export_uuid,complete:false}`; same revision retry may return complete:true |
| page | workout_uuid, export_uuid, samples | `{observed_count:N}` (cumulative distinct sample UUID count) |
| finalize | workout_uuid, export_uuid, observed_count | `{export_uuid,observed_count,complete:true,coverage:"observed_only"}` |
| delete | workout_uuid | `{deleted_exports:N}`; removes all revisions and samples of this workout |
| delete_all | none | `{deleted_exports:N}`; removes all this authenticated user's detail revisions/samples |

Sample fields: sample_uuid, metric_type, value, unit, source_device, started_at,
ended_at. At most 500 samples and 256 KiB per request; no empty page. Up to 100,000
distinct samples per revision. unit is a nonempty string up to 64 characters;
source_device up to 256. ended_at cannot precede started_at. Preserve the converter's
original units; backend performs no conversion or cadence inference.

query_types must be a nonempty, duplicate-free subset of these identifiers:

- HKQuantityTypeIdentifierHeartRate
- HKQuantityTypeIdentifierRunningSpeed
- HKQuantityTypeIdentifierRunningPower
- HKQuantityTypeIdentifierRunningStrideLength
- HKQuantityTypeIdentifierRunningVerticalOscillation
- HKQuantityTypeIdentifierRunningGroundContactTime
- HKQuantityTypeIdentifierStepCount

Every sample type must be declared by begin. For samples unavailable to HealthKit,
an empty observed snapshot is allowed but never claims permission or absence.
The query_types list describes queried types, not successful permission grants.

Use one export UUID throughout a revision. Exact duplicate pages are idempotent;
changing a sample under the same UUID is a conflict. Finalize count must equal the
stored distinct UUID count. Finalized revisions are immutable. Begin retries with
different query_types fail. A new partial revision leaves the prior one visible.
Ordering is a server-generated monotonic bigint revision, not client time. A late
older completion cannot replace a newer current revision. All writes and deletion
serialize per tenant. After deletion, a new explicit begin can create a revision;
the native cancellation/generation guard must stop previously queued export work.

Up to 16 revisions per workout are retained, including pending revisions. No
automatic expiration or raw-metric compaction applies. At the limit, report the
conflict; never silently delete history. Explicit delete removes all revisions
before the user deliberately exports again. This storage/retention behavior must
be disclosed before enabling. The optional SQL is not in the default installer.

Errors: 400 invalid payload/body, 401 missing/invalid authentication, 405 method,
413 actual streamed bytes exceed cap, 409 named revision/count/type conflict,
503 sanitized storage/service failure. Never convert a 409/503 into success.
No raw provider error, sample value or secret is logged or returned in an error.
If finalize response is lost, retry finalize; if begin says complete:true, do not
replay page writes. Verify current counts separately when presenting completion.

MCP opt-in uses the same environment flag. `get_workout_details(workout_uuid,
cursor=None,limit=200)` returns only a current completed snapshot, max 500 samples
per page. Cursors are bound to tenant/workout/revision and invalidated on replacement.
Status snapshot_unavailable has coverage unknown; complete_snapshot has coverage
observed_only. This is structured JSON, not a full-data/permission guarantee.

Exact associated StepCount rows additionally expose derived_cadence: the count
divided by that sample's elapsed minutes, including pauses. This is explicitly
not recorded/instantaneous cadence or a workout average. Invalid/zero-duration
intervals report unavailable; heart-rate and other rows get no cadence annotation.
