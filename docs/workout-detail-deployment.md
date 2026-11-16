# Workout details: review and deployment packet

Candidate only, 2026-11-16. No production migration, endpoint deployment, MCP package
release, native release or feature enablement performed. Submitted build 84 remains
unchanged. Structured JSON is the requester's alternative to FIT; binary FIT is not
required for this slice. Optional GPS snapshots and clearly labeled per-sample
elapsed step rates are implemented behind separate flags; derived distance splits
and automatic background route refresh are not claimed.

## Before approval

- Independent SQL, tenant/security, failure-handling and native UI review must pass.
- Actual local PostgreSQL/MCP proof, HTTP validation and full existing MCP suite
  must pass; removing the count guard must fail the real database proof.
- Native default-off consent, cancellation, supported types, observed counts and
  deletion behavior must be verified on the integrated source. No source data may
  be transferred as part of deployment verification without the approved scope.
- Retention is until explicit deletion, separate from raw-metric compaction; max
  16 revisions per workout and 100,000 samples per revision. This must be visible
  before opt-in. Quantity endpoints reject GPS; route endpoints require separate
  location consent, capability and opt-in. No arbitrary metadata is accepted.
- Route collection requires a fresh legal/privacy decision on precise-location
  disclosures and the next native release's manifest/public policy before enabling.
  Existing build 84 declarations must not be silently reused for new location data.

## Concrete rollout (requires final approval of target and scope)

1. Identify the user-owned Supabase project and verify backup/restore readiness.
   Apply `supabase/optional/workout-details-v1.sql` once; it is transactional and
   intentionally fails if conflicting existing relations are present. It creates
   no authenticated/anon grants; only service role may call the writer.
2. Deploy the separate `workout-details` Edge Function with the feature flag absent.
   Verify POST returns feature_disabled and ordinary healthkit-ingest is unchanged.
3. Only after native opt-in/erase integration passes, set the endpoint environment
   flag `HEALTH4AI_WORKOUT_DETAILS_ENABLED=true`. Verify capabilities using an
   existing authenticated test identity; it succeeds only if the RPC is installed.
4. Enable the same flag in the user's MCP environment only when they choose the
   feature. Existing installations remain disabled by default. MCP reads only the
   configured user's current finalized revision and uses a read-only repeatable
   transaction for consistent pages.
5. With explicitly selected existing source workout data, verify begin/page/finalize,
   MCP readback and explicit delete. Do not manufacture phone Health records or
   reset existing anchors. Publish the native implementation as a later release.

For routes, separately approve/install `supabase/optional/workout-routes-v1.sql`,
deploy `workout-routes` initially disabled, review route privacy/consent, then enable
`HEALTH4AI_WORKOUT_ROUTES_ENABLED=true` only for the approved target and MCP user.
Native route permission must follow an explicit user action, after capability
discovery. Follow `workout-route-wire-v1.md`; verify valid and invalid source counts,
unknown altitude and route deletion independently of quantity details.

## Rollback and deletion

Unset the Edge Function/MCP flags to stop new access, and turn native opt-in off.
Disabling is not deletion. Before disabling an endpoint needed for erasure, use
the authenticated delete/delete_all operations and verify returned counts plus
scoped storage readback. Revoking a token alone also does not delete details.
Do not drop schema as an automatic rollback: that irreversibly destroys exports.
An explicitly approved uninstall may drop the RPC and both tables after export or
backup and a verified user-owned deletion decision.

If routes were used, route delete/delete_all must also succeed and be verified;
quantity deletion does not remove route tables. A partial erase must stay visible
as a failure. Disabling either endpoint before deletion can prevent that deletion.

The schema retains older revisions until delete. A late in-flight page cannot
write after erase without an explicit new begin; native connection-generation
guards must prevent queued old work from beginning again after deletion/sign-out.
No automated cleanup or production verification is hidden in these instructions.

## Local commands

`deno test --allow-read supabase/functions/workout-details/handler_test.ts`

Also run `supabase/functions/workout-routes/validation_test.ts` with the same command.

`H4A_TEST_POSTGRES_URL=<local-only URL> python3 scripts/tests/workout_detail_db_proof.py`

`H4A_WORKOUT_MUTANT=missing_count_guard` runs the deliberately broken local schema
and must fail at the partial-count assertion. Tests create/drop a unique database;
the URL guard refuses non-local hosts. CI runs both controls and the HTTP tests.
