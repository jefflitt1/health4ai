# Sync and privacy review, 2026-11-04

Scope: the iOS sync code (Google Sheets destination and Supabase destination), OAuth and token
storage, logging, and a privacy pass over the web site (`web/`). Automated run, branch
`cloud/h4a-review-20261104`.

**Limits of this review.** Xcode and the Swift toolchain are not available in the sandbox. No Swift
was built or run, and `ios/scripts/test_sheets_logic.sh` was not run. Every iOS finding below comes
from reading the code, and every proposed Swift fix is untested. No Swift files were edited.
Findings marked PLAUSIBLE depend on HealthKit or Google API behaviour that needs a device or API
check before anyone acts on them.

Note on the premise: the app has two destinations, a Google Sheet (the default since 1.0.2) and
a Supabase project the user owns. Both were reviewed.

Severity scale: High (data loss, privacy exposure, or a false privacy claim), Medium (wrong or
duplicated data a user would notice), Low (edge case or hardening), Info (no defect, for the record).

## Historical scope and later resolutions

Reconciled 2026-11-16 against main `00775bbb`; the text and line references below
record the November 4 snapshot, not a new claim about current production behavior.

- I1, I2 and I3 were addressed in [PR #51](https://github.com/jefflitt1/health4ai/pull/51).
  That PR also addressed I6's single-flight refresh issue; its separate refusal/UI
  concern is not closed by this documentation update.
- W2 and W3's disclosure gaps were addressed in
  [PR #57](https://github.com/jefflitt1/health4ai/pull/57). Current policy follows
  configured website vendors and distinguishes website collection from HealthKit sync.
- W1 consent controls and explicit recording configuration are handled separately
  by [PR #42](https://github.com/jefflitt1/health4ai/pull/42); this audit does not deploy them.
- W5 is the only product change in this PR: the legacy-post banner names both
  Google Sheets and the user's own Supabase project.
- Other findings remain historical observations/proposals, requiring current-source
  validation before fixes. Legal interpretations below are original reviewer claims,
  not a current legal determination. Proposed removals of configuration alone do
  not establish that a vendor's remotely controlled recording feature is disabled.

## Summary

| # | Sev | Area | Where | Finding |
|---|-----|------|-------|---------|
| W1 | High | Web privacy | `web/src/layouts/Layout.astro:111-123` | PostHog, Microsoft Clarity and the Meta Pixel load on every production page with no consent step |
| W2 | High | Web privacy | `web/src/pages/privacy.astro:31`, `:99` | Policy says "We do not use advertising cookies or trackers" and names only PostHog, while the layout is wired for the Meta Pixel and Clarity |
| W3 | Medium | Web privacy | `web/src/components/posthog.astro:9`, `privacy.astro:31` | PostHog session recording is configured but the policy describes only page views and events |
| W4 | Info | Web/infra | `cloudflare/api-proxy/worker.js:8` | A worker routes `api.health4.ai/ingest` to the author's own Supabase project |
| W5 | Fixed | Web copy | `web/src/pages/blog/[slug].astro:103` | Legacy-post banner said the app "syncs only to a Supabase project", which leaves out the Google Sheet destination |
| I1 | Medium | Sheets retry | `ios/Health4AI/SheetsClient.swift:188` | 5xx retry re-POSTs `values:append`, which is not idempotent: duplicate Workouts / Sleep stages rows |
| I2 | Medium (PLAUSIBLE) | Units / locale | `ios/Health4AI/SheetsLogic.swift:207-210`, `SheetsClient.swift:75` | Decimals are sent as "7.50" strings with USER_ENTERED; in a comma-decimal sheet locale they can parse as text or dates |
| I3 | Medium | Sheets errors | `ios/Health4AI/SheetsClient.swift:182-185`, `SheetsSink.swift:235-239` | Any 403 with status PERMISSION_DENIED (including API disabled at the project level) makes the app forget the user's sheet |
| I4 | Low | First sync | `ios/Health4AI/SheetsSink.swift:252-266` | Sheet creation succeeds, header write fails: state not saved, next pass creates a second spreadsheet |
| I5 | Low | OAuth | `ios/Health4AI/GoogleAuth.swift:177-179`, `:161-166` | A stale in-flight refresh can wipe a newer sign-in, or re-cache an access token after Disconnect |
| I6 | Low | Supabase auth | `ios/Health4AI/AuthManager.swift:193-227`, `:253-261` | No single-flight refresh for a rotating refresh token; a refused refresh never asks the user to sign in again |
| I7 | Low (PLAUSIBLE) | HealthKit paging | `ios/Health4AI/SyncEngine.swift:659-664`, `:703` | The page-drain loop counts only added samples, while the query limit also counts deleted objects |
| I8 | Low | DST / midnight | `ios/Health4AI/SheetsLogic.swift:74-76` | `SleepMath.night` adds 12 absolute hours; on a midnight fall-back the Sleep stages tab and Daily tab disagree on a night |
| I9 | Low | Late data | `ios/Health4AI/SheetsSync.swift:177`, `:268`, `:336` | Daily and Workouts re-read only 2 days back; data that reaches Health later than that never reaches the sheet |
| I10 | Low | Keychain | `ios/Health4AI/ContentView.swift:122-140` | `CredentialKeychain.save` ignores the `SecItemAdd` status and deletes first, so a failed add drops the old value without any error |
| I11 | Info | Logging | several | No health values in logs and no analytics SDK in the app; dates of oldest samples are logged public |

## Web findings

### W1 (High). Third-party trackers load before any consent

`Layout.astro` includes, on every page:

- `<PostHog />` (`posthog.astro:9`): `capture_pageview`, `capture_pageleave`, `persistence:"localStorage"`,
  and a `session_recording` block. Runs whenever `PUBLIC_POSTHOG_PROJECT_TOKEN` and
  `PUBLIC_POSTHOG_HOST` are set at build time.
- Microsoft Clarity (`Layout.astro:115-117`) when `PUBLIC_CLARITY_PROJECT_ID` is set: session replay and
  first-party cookies (`_clck`, `_clsk`).
- Meta Pixel (`Layout.astro:120-123`) when `PUBLIC_META_PIXEL_ID` is set: `fbq('track','PageView')`, the
  `_fbp` cookie, and a `<noscript>` image beacon to `facebook.com/tr`.

The only gate is a hostname check that skips preview and local hosts. There is no consent banner,
no opt-in, and nothing waits for one. The CSP (`Layout.astro:108`) lists all three vendors, so the
intent is clearly for them to run.

The build env is set in the Cloudflare Pages dashboard, which this review cannot see. If any of these
variables is set in production:

- A visitor from the EU or UK gets non-essential storage (localStorage, cookies) and a third-party
  beacon before agreeing to anything. ePrivacy and UK PECR require consent for that.
- With the Meta Pixel, every page URL a visitor opens goes to Meta, for example
  `/blog/apple-watch-heart-rate-claude/` or `/blog/hrv-analysis-claude-ai/`. On a health app's site
  that is the pattern the FTC acted on (GoodRx, BetterHelp) under the Health Breach Notification Rule
  and Section 5.

Proposed fix (needs an owner decision, so it was not made unattended): load none of the three until
the visitor opts in, through a small consent component that sets a flag and only then injects the
snippets. Alternatively, drop Clarity and the Meta Pixel and run PostHog cookieless
(`persistence: "memory"`, recording off) without consent. Removing the Meta Pixel is the
lowest-effort way to make the privacy policy true as written (see W2).

### W2 (High). Privacy policy contradicts the layout

`privacy.astro:31`: "Usage data: anonymous page views and feature interaction events via PostHog
(US-hosted). PostHog never receives health data. We do not use advertising cookies or trackers."
`privacy.astro:99` repeats the last sentence.

The Meta Pixel is an advertising tracker, and Clarity is a session-replay tool the policy never
mentions. If `PUBLIC_META_PIXEL_ID` or `PUBLIC_CLARITY_PROJECT_ID` is set in production, the policy
is false. Whichever way W1 is settled, the policy has to name every vendor that loads. This is legal
copy, so it was reported here and not edited.

### W3 (Medium). Session recording is not disclosed

`posthog.astro:9` configures `session_recording: {maskAllInputs: true, maskTextSelector: "[data-ph-mask]"}`.
Whether recordings are captured is set in the PostHog project settings, which this review cannot see.
The policy describes only "page views and feature interaction events". If recording is on in the
project, disclose it; if it is not wanted, remove the block so turning it on in PostHog cannot
quietly start recording.

Side note (PLAUSIBLE, functional, not privacy): Clarity's loader at `www.clarity.ms/tag/<id>` fetches
its main script from `scripts.clarity.ms`, which the CSP `script-src` does not allow. Clarity may be
half-loaded today. Check the browser console on the live site before relying on Clarity data.

### W4 (Info). `api.health4.ai` proxy to the author's Supabase project

`cloudflare/api-proxy/worker.js:8` forwards `api.health4.ai/ingest` to
`https://donnmhbwhpjlmpnwgdqr.supabase.co/functions/v1/healthkit-ingest`. Nothing in the app points
there: `SyncState` defaults `serverURL` and `supabaseProjectURL` to empty (`SyncState.swift:303-305`)
and builds the endpoint from the user's own project URL (`:231-245`). So no site claim is false
today. If this route is still deployed, though, anyone who enters `api.health4.ai/ingest` sends health
data through a health4ai-operated worker, which contradicts "There is no health4.ai account and no
health4.ai server in the path" (`how-it-works.astro:207`). Recommend retiring the route, or saying in
the worker header that it serves only the author's own data.

`WaitlistClient.astro` also posts to that project, but nothing renders it (the existing performance
test asserts that), so it is not a live data flow.

### W5 (Fixed in this PR). Legacy-post banner named only Supabase

`web/src/pages/blog/[slug].astro:103` told readers of every `legacySetup` post (about a dozen,
including `/blog/apple-health-mcp-server/`) that "health4.ai now syncs only to a Supabase project
you own". Since 1.0.2 the default destination is a Google Sheet in the user's own Drive. Both
destinations belong to the user, but the one sentence about where data goes on those pages named
only one. The new text names both. Test: `web/scripts/performance.test.mjs`, "legacy-setup banner
names both destinations the app writes to". It failed against the pre-fix build and passes after.

## iOS findings

The detailed I1–I11 scenarios and proposed fixes are retained in the
[iOS findings appendix](cloud-sync-review-2026-11-04-ios.md).

## Checked and found correct

- First sync and empty first chunk: an empty chunk before today is skipped, not failed, and does not
  advance `lastWrittenDay`. The pass throws `noHealthData` only when no chunk through today had data
  (`SheetsSync.swift:283-295`). The rebuild path refuses to overwrite when the history found starts
  later than the sheet's first row (`:241-245`).
- Daily upsert by date with UNFORMATTED/SERIAL date reads (`SheetsClient.swift:49-65`), so re-runs and
  interrupted passes update in place and do not append duplicates. Progress is saved per chunk, after
  the write.
- Refused-cell handling keeps the value already in the sheet instead of blanking it
  (`SheetsSync.swift:66-81`, `:430-450`).
- Supabase path: anchors advance only after a page posts (`SyncEngine.swift:697-701`), and the ingest
  upsert key makes a re-post idempotent, so a retry after a mid-page failure re-sends rather than
  drops or duplicates.
- Unit conversions: steps and flights `.count()`, energy `.kilocalorie()`, exercise `.minute()`, HR
  count/min, HRV `ms`, VO2 mL/(kg*min), distance and mass in the units chosen at sheet creation and
  shown in the header (`DailySummaryBuilder.swift:13-40`, `:214-243`).
- Formula injection: external text (source names, workout names) is prefixed with `'` when it starts
  with `= + - @` (`SheetsLogic.swift:200-203`).

## Verification in the original review

- `cd web && npm ci && npm run build` (includes the postbuild tests): exit 0, 12/12 performance tests
  and 34/34 agent-readiness tests pass after the fix.
- New test failed before the fix: `not ok 1 - legacy-setup banner names both destinations the app
  writes to`, `error: 'banner must not say Supabase is the only destination'`.
- Swift: not built, not tested (no toolchain in the sandbox).

## Documentation and banner follow-up, 2026-11-16

Merged main `00775bbb` without conflicts. `npm ci && npm run build` passed:
12 performance/banner tests and 34 agent-readiness tests. Replacing only the
emitted banner sentence with its pre-fix text makes the new assertion fail.
Real Chromium renders at 375px and 1440px show both destinations, no horizontal
overflow and no external requests (local build with request interception).
The long audit was split into this overview/web report and the linked iOS appendix;
original iOS findings were preserved. No Swift fixes or device changes in this PR.
