# Exact workout details: next slice of #54

Implementation design, 2026-11-16. Not enabled, installed,
deployed or advertised by the app. Submitted 1.0.7 build 84 is unchanged.

## Why a separate store

The requester wants running time series and routes in their own Supabase project,
without a computer exporting FIT files. Recorded events/UUIDs are already in #59.
`HealthSample.swift` has no quantity sample UUID. The installed bootstrap metric
key is user/type/device/start time, not HealthKit identity. Hour replacement and
historical compaction deliberately discard individual rows. Therefore exact links
cannot safely reference those rows, and timestamp overlap is not an association.
The existing ingest's 4 KiB metadata cap also cannot contain a full time series.

Apple provides an exact [workout association predicate](https://developer.apple.com/documentation/healthkit/hkquery/predicateforobjects(from:)-5irg9).
Each allowed quantity type needs its own query. An empty query is not proof of
denied permission or proof no samples exist: HealthKit hides read authorization.

## Proposed storage contract

The next implementation needs tenant-scoped, UUID-keyed export revisions and
quantity samples, a complete-revision read view and an atomic finalizer. No SQL,
app exporter, MCP tool or endpoint is implemented by this design document. Before
integration into the customer bootstrap, local tests must execute the real SQL on
a disposable database in `jgle-test-db`, never production.

Required invariants: each export revision becomes immutable after finalization.
A retry with the same count is idempotent; a mismatched count fails. A partial new
revision never hides the prior current one. A late older revision cannot replace
a newer finalized one. Tenant and workout identity belong in every key and foreign
key. Tables must be closed to anon/authenticated; only the trusted ingest service
can write. The read view must expose finalized current revisions only. Finalizer
completion means all observed pages arrived, not that HealthKit disclosed every
source sample.

This is a proposed storage contract, not the requested end-to-end feature. It does
not contain coordinates, infer cadence/splits, change metric aggregation, request
permission or change existing retention. The acceptance matrix below is not yet run.

## Proposed implementation sequence

1. Review this contract and decide detail retention/erase behavior. Recommended:
   user-owned details retained until explicit deletion, clearly disclosed before
   opt-in; never imply the existing raw-metric compactor deletes them. Add erase
   support before enabling collection. Until reviewed, storage remains inactive.
2. Add a separately versioned `workout_details_v1` capability and authenticated
   ingest operations (begin, bounded sample page, finalize, delete). Stamp user
   identity from verified JWT, never from payload. Limit pages to 500 samples and
   256 KiB; reject unknown fields, nonfinite values and malformed UUIDs. Store no
   arbitrary HealthKit metadata or location. Backend snapshot count verifies the
   acknowledged distinct sample UUID count. Reuse an export UUID for page retries.
3. Add opt-in Supabase detail export, off by default, with clear destination and
   retention copy. Query exact associations for already selected running types:
   heart rate, speed, power, stride length, vertical oscillation, ground contact
   time and step count. Export UUID, original unit/value/time/source; never hourly
   merged rows. Checkpoint each acknowledged page under connection generation and
   destination identity. Capability absence leaves ordinary sync working and
   reports unsupported details. Failed/locked queries do not finalize or advance
   the detail checkpoint. Do not reset existing anchors.
4. Add authenticated MCP `get_workout_details(workout_uuid, cursor, limit)` using
   tenant-scoped keyset pagination over the current immutable revision. Return
   export UUID, query types, observed counts and explicit coverage state. Bind
   cursor to tenant/workout/revision; a replaced revision requires restart rather
   than mixing pages. This supplies structured JSON without FIT infrastructure.
5. Only then add optional route read permission and route storage/update/delete
   protocol. Apple says [routes can arrive or change after workouts](https://developer.apple.com/documentation/healthkit/reading-route-data),
   requiring anchored route updates and batched location queries. A workout-only
   observer cannot guarantee route completeness. Separate location privacy review
   and opt-in copy are required; do not silently add routes to Complete scope.

FIT, distance-derived splits and cadence estimates follow usable exact data;
do not invent them from sparse or overlapping rows. Recorded events remain distinct
from computed intervals. The requested provider location history is sensitive even
when routed directly to a user-owned backend.

## Acceptance before enablement

- Real local PostgreSQL: identity collisions, cross-tenant foreign keys/access,
  partial revisions, exact-count finalization, retry, immutable completed samples,
  stale revision rejection and deletion cascades. Mutation controls must fail.
- Ingest: JWT ownership, byte/page bounds, unsupported capability, interrupted page,
  duplicate retry and deleted/replaced workout, without raw data in logs.
- Native: actual HealthKit associated versus merely overlapping samples; protected
  data deferral; destination/sign-out race; restart midway; no permission expansion.
- MCP: tenant isolation, stable ordering, empty versus unknown coverage, cursor
  replay after replacement. Physical acceptance uses eligible existing authorized
  data and the user's existing destination, without synthetic phone writes.

## Applicable rules and verification

Root AGENTS: isolated worktree, verify before done, local DB tests, independent
review. README SQL rules (line 251): explicit grants and bootstrap integration only
when installable. `docs/workout-export.md`: no inferred associations or completeness.
JGLV legal/privacy release rule: retention/location changes reviewed before enabling.
Compound practices §2–3: evidence-based scope, cited rules, simplification before review.
The graph index returned older conversion source; current checked-out files were
read directly to verify these claims. No project-specific AGENTS/CLAUDE file found.
