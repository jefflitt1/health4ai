# Optional route wire v1

Location is a separate explicit opt-in, never implied by quantity detail consent.
POST to the same user-owned Supabase origin `/functions/v1/workout-routes`, with
the existing user JWT. Flag `HEALTH4AI_WORKOUT_ROUTES_ENABLED=true` is required;
absent/false gives 404 feature_disabled. It is separate from quantity detail flags.
Capabilities reports workout_routes_v1 only after the optional route RPC is ready.
No GPS collection, deployment or production storage is enabled by this source change.

Common keys: operation, workout_uuid and export_uuid. Standard UUID strings.
begin adds `routes:[{route_uuid,source_count}]`, one entry per exactly associated
HKWorkoutRoute. source_count is HKSeriesSample.count. At most 32 routes and 100,000
total source points. Empty routes is allowed, with observed_only coverage, not proof
of permission or no route. Export UUID is distinct from the quantity revision.

page adds `points:[{route_uuid,point_index,timestamp,latitude,longitude,altitude,
horizontal_accuracy,vertical_accuracy}]`. All keys required. At most 500 points
and 256 KiB per request. point_index is the original zero-based source order,
not the filtered-array position. Identical retries are idempotent; changed payloads
at the same route/index conflict. Indices must be below the declared source count.
Coordinates are finite decimal degrees, lat -90..90, lon -180..180; timestamp is
canonical UTC Z with 0–3 fractional digits. Accuracy and altitude use meters.
horizontal_accuracy must be finite and nonnegative; vertical_accuracy must be
finite, but a negative unknown sentinel is allowed. altitude must be null if
vertical_accuracy is negative; otherwise a finite value or null. No speed/course,
arbitrary metadata or unvalidated coordinate fields are stored in this slice.

Native code must count invalid source records explicitly rather than silently
claim a complete route. Invalid coordinate/time/horizontal-accuracy records are
omitted with gaps in point_index. Unknown altitude alone does not discard a point.
finalize adds `invalid_counts:[{route_uuid,invalid_count}]`, every declared route
exactly once. Stored valid point count + invalid_count must equal source_count for
each route. Report those counts to the user/MCP. Errors or unfinished HealthKit
query callbacks never finalize. A positive invalid_count is visible partial
quality, not a clean full route claim.

begin returns {export_uuid,complete}; page returns {observed_count} across all routes;
finalize returns {export_uuid,complete:true,coverage:observed_only,observed_count,invalid_counts}.
observed_count is the total VALID stored points, verified by the server; compare it
against the native distinct sent-point count before presenting success.
The completion flag means accounted-for observed source entries, not full location
availability or fitness-grade accuracy. Server monotonic revisions prevent older
late completion replacing newer data; pending refresh preserves the old snapshot.

delete takes only operation/workout_uuid and deletes all that workout's route
revisions. delete_all takes only operation and deletes all the authenticated user's
routes. Both return deleted_exports. They are separate from quantity deletion;
the native Erase All flow must attempt and verify both when both features were used,
and must not claim total deletion if either endpoint fails. Both writers use the
same tenant serialization lock. Stop/generation-cancel old work before deletion.

Retain at most 16 revisions per workout until explicit deletion; no hidden expiry.
HTTP/auth/errors/retries follow quantity detail wire v1. Native export is a manual
observed snapshot: later Apple route smoothing/replacement needs another export.
Continuous background route updates are not claimed. A future anchored observer
needs its own durable retry/delete acceptance before making that promise.
