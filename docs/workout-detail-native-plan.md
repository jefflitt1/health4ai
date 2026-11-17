# Manual workout detail export

Scope (2026-11-16): default-off, Supabase-only, selected running workouts.
Use exact HealthKit association; query at most 500 objects per anchored page,
intersect seven supported types with the existing user scope, preserve canonical
units and source intervals. No FIT, quantity permission expansion, background export,
or assertion that an empty result means permission was granted. Scope was extended
by the parent task to separately consented manual GPS route export, with its own
optional permission, capability, endpoint, storage and deletion controls.

Consent binds endpoint and user; every suspension validates connection revision,
sign-out generation, endpoint, user identity, operation generation and current scope.
Each explicit export gets a new UUID. A request retry keeps identical bytes within
that attempt; no cross-launch resume or atomic HealthKit snapshot is claimed.
Deletion stays usable with consent off. Local preferences use the existing hkb erase
namespace. Remote deletion is explicit and requires confirmation.

Implementation: small wire/client, exact HealthKit reader, export coordinator, and
SwiftUI screen; Privacy adds a navigation link. Test exact wire output, bounded pages,
lost-response retry identity, revoked consent/destination/account changes across
suspended calls, truthful response validation and delete without consent. Then run
signed simulator tests, simplify only changed code, independent security/code review
and Sasha review before PR/merge. Backend stays disabled in production.

Applicable rules:
- ~/AGENTS.md:40 — actual tests and magnitude, not compilation alone.
- ~/AGENTS.md:47 — independent review before live change; no deploy in this lane.
- ~/AGENTS.md:53 — isolated feat/workout-detail-native worktree only.
- ~/AGENTS.md:61 — local fixtures/database; no production collection.
- ~/claude-agents/bu/jglv/AGENTS.md, Rules specific to this BU — product privacy
  review and rendered UI gate before release.
- design.md — semantic colours, honest observed counts, 44pt controls, XXXL layouts,
  confirmation for destructive actions and Sasha gate.
- No additional repository AGENTS.md or path-specific .claude rule was found.

Known limitation: quantity queries are separate observations, not an atomic snapshot.
Retain up to 16 revisions per workout on the optional server, with explicit deletion;
show errors rather than discarding earlier revisions to make space.

Initial quantity verification: 136 signed simulator tests passed (13 new). First
independent review found UUID case mismatch with PostgreSQL responses; normalize
UUID text and test lowercase server responses rather than echoing request identity.
Initial combined quantity/routes: 19 focused tests passed before visual fixtures.
Simplification pass: retained explicit suspension-boundary checks; no safe deletion
of validation found. Route collector isolates completion/cancellation and bounded
multi-callback accumulation; it never assumes one callback means all route points.

Render gate uses DEBUG-only fixtures through existing Privacy screenshot routing.
Fixtures use example.invalid and no real credentials or data. They exercise the
actual screen layout; they are not physical HealthKit or hosted acceptance proof.
See workout-detail-privacy.md for the candidate data map and release obligations.
