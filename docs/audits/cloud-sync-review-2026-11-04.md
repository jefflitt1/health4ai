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

### I1 (Medium). 5xx retry duplicates appended rows

`SheetsClient.send` (`SheetsClient.swift:157-198`) retries `429` and `500...599` up to three times for
every method. `append` (`:136-144`) is `values:append` with `INSERT_ROWS`, which is not idempotent. The
Workouts and Sleep stages paths dedupe by ID once, before the append (`SheetsSync.swift:468-471`,
`SheetsSync+SleepStages.swift:47-62`), and not between retries.

Failure scenario: a catch-up append of 2,000 workouts reaches Google, Google applies it, and the
response is a 502/503/504 from the front end (common on a slow phone link with a large body). `send`
sleeps 2 s and POSTs the same 2,000 rows again. The Workouts tab now holds every one of those
workouts twice, and nothing later removes duplicates, because the ID check only stops new appends.
`values:batchUpdate` (Daily) is idempotent and safe to retry; `append` is not.

Proposed fix: give `send` a `retryServerErrors: Bool` parameter (default true) and pass false from
`append`. Return the 5xx to the caller; the next pass re-reads the ID column and appends only what
is missing, as the `appendInPieces` comment already assumes. Keep the 429 retry, since a rate-limited
request was not applied. Test it in `SheetsSyncTests.swift` with a fake whose `append` applies the
rows and then throws `SheetsError.http(status: 503, ...)`, asserting the next pass adds nothing.

### I2 (Medium, PLAUSIBLE). Decimal strings and the sheet's locale

`SheetCell.number` formats with `en_US_POSIX` ("7.50", "72.4") and `writeRanges`/`append` send them as
JSON strings with `valueInputOption: USER_ENTERED`. Sheets parses USER_ENTERED strings in the
spreadsheet's locale. `createSpreadsheet` (`SheetsClient.swift:23-33`) does not set
`properties.locale`, so the locale comes from Google's default for the account.

Failure scenario (to confirm with a German or French Google account): the sheet's locale is `de_DE`.
"7.50" in Sleep (h) is not a number in that locale and is stored as text, or for values like "1.5"
may be read as a date (1 May). Charts and an AI connector then see text or dates where sleep hours,
distance and weight should be. The same happens if a user changes File > Settings > Locale later.

Proposed fix: send numeric cells as JSON numbers (`Double`, not `String`) in the `values` arrays.
Sheets stores a JSON number as a number whatever the locale, and dates stay as "yyyy-MM-dd" text,
which every locale parses. Setting `"locale": "en_US"` at creation is a weaker fix, because it does
not survive a later locale change.

### I3 (Medium). Any PERMISSION_DENIED forgets the user's sheet

`SheetsClient.swift:182-185` maps every 403 whose body contains `PERMISSION_DENIED` to
`spreadsheetMissing`, and `SheetsSink.swift:235-239` then calls `SheetsDestinationState.clear()`.
Google returns HTTP 403 with status `PERMISSION_DENIED` for more than a sheet the app can no longer
see: reason `SERVICE_DISABLED` (Sheets API turned off on the Cloud project `health4ai`) and
`ACCESS_TOKEN_SCOPE_INSUFFICIENT` both use it.

Failure scenario: the Sheets API is disabled or suspended on the project for an hour. Every user's
next pass gets 403 PERMISSION_DENIED, every app forgets its spreadsheet ID, and Home offers "Create a
new sheet". Users who tap it end up with their history split across two files. Those who do not tap
it stop syncing until they act, even after the API comes back.

Proposed fix: decode `error.details[].reason` and treat only a 404, or a 403 with no
`SERVICE_DISABLED` / `ACCESS_TOKEN_SCOPE_INSUFFICIENT` / quota reason, as "sheet missing". Better
still, confirm with one Drive `files.get?fields=id,trashed` call before clearing state, and do not
clear on an ambiguous answer.

### I4 (Low). Orphan spreadsheets on a failed first write

`SheetsSink.createSheet` (`SheetsSink.swift:252-266`) creates the file, writes headers and the About
tab, and only then saves `SheetsDestinationState`. If the header write throws (network drop, 429
retries used up, background time ending), the ID is lost. The next pass sees no saved state and
creates another "health4ai" spreadsheet. Repeated failures leave several empty sheets in the user's
Drive with the same name, and the user cannot tell which one the app uses.

Proposed fix: save the state right after `createSpreadsheet` returns, with a `headersWritten: false`
flag, and write headers at the start of a pass while that flag is false. The header write is an
idempotent `batchUpdate`.

### I5 (Low). Google token store races

`GoogleTokenStore.postToken` calls `forgetLocally()` on any `invalid_grant` (`GoogleAuth.swift:177-179`).
It does not check that the refresh token it sent is still the stored one.

Failure scenario: a background pass starts a refresh with token A. The user taps Disconnect
(`signOut` revokes A) and reconnects at once, which stores token B. A's request comes back
`invalid_grant`, `forgetLocally()` deletes B, and the user sees "Reconnect Google" seconds after
reconnecting. In the same window, a refresh that started before Disconnect and finishes after it calls
`remember()` (`:161-166`) and caches a fresh access token. If the revoke failed (offline), the pass
can go on writing for up to an hour after Disconnect.

Proposed fix: keep a generation counter that `exchange` and `forgetLocally` both bump. Capture it
before the network call, and apply `remember` / `forgetLocally` only if it is unchanged. Optionally
single-flight `validAccessToken` with a stored `Task` so concurrent callers share one refresh.

Storage itself is right: the refresh token is in the Keychain
(`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, `ContentView.swift:136`), the access token is in
memory only, the token-error body is logged `.private` (`GoogleAuth.swift:181`), and PKCE plus
`state` are checked (`:207-271`).

### I6 (Low). Supabase refresh: no single-flight, no re-sign-in on refusal

`AuthManager` stores the access token, refresh token and email in the Keychain (`AuthManager.swift:265-290`),
not UserDefaults. Only the non-secret expiry goes to UserDefaults (`:182`, `:226`). Two weaknesses:

- `validToken` (`:253-261`) has no single-flight. Live sync (`SyncEngine.swift:645`) and the backfill
  (`BulkExportManager.swift:529`) can both find the token expired and each POST the same refresh token.
  Supabase rotates refresh tokens. Inside the reuse interval (10 s by default) both succeed. Past it,
  reuse detection can revoke the session and sign the user out. Unlikely, since the two calls are close
  together, but cheap to rule out with one stored `Task`.
- On any non-200 refresh (`:217-219`) the error is a generic "Token refresh failed". A 400
  `refresh_token_not_found` or `invalid_grant` (session revoked in the dashboard, user deleted) keeps
  the stale tokens, `isSignedIn` stays true (`:133-135` checks presence, not validity), and every pass
  fails the same way with no "sign in again" prompt. Proposed fix: on 400/401 from the refresh
  endpoint, call `signOut()` and surface a re-sign-in state.

### I7 (Low, PLAUSIBLE). Page drain ignores deleted objects

`syncTypeLocked` stops draining when `samples.isEmpty` (`SyncEngine.swift:659-664`) or
`samples.count < anchorPageSize` (`:703`), counting only `added`. Apple documents the
`HKAnchoredObjectQuery` limit as "the maximum number of samples and deleted objects to return". A
page of 3,000 additions and 2,000 deletions hits the limit with `added.count == 3000`, and the loop
stops as if caught up. Nothing is lost, because the anchor is saved and the next observer fire
continues. But a burst of deletions (the user removing an app's data from Health) can push the
remaining additions back one observer or BGTask wake per page. Proposed fix: return `deleted?.count`
from `queryAnchoredSamples` and stop only when `added + deleted < anchorPageSize`. Confirm the limit
semantics on device first.

### I8 (Low). Sleep night label on a midnight DST change

`SleepMath.window(for:)` is noon to noon in wall-clock time (`SheetsLogic.swift:42-47`), but
`SleepMath.night(for:)` adds 12 absolute hours (`:74-76`). They agree except when the clock moves at
midnight. America/Santiago, for example, falls back from 24:00 to 23:00 on the first Sunday in April.

Failure scenario: a nap recorded Saturday 12:30 to 13:10 falls in Sunday's window, so the Daily tab
counts it under Sunday. `night` gives 12:30 + 12 h = Saturday 23:30 (the hour repeats), so the Sleep
stages tab labels it Saturday. The About tab promises the two agree. Proposed fix: compute the night
from wall-clock components, so the night is the start day plus one if the hour is 12 or later, and
the start day otherwise. Add a test with an `America/Santiago` calendar to `SheetsLogicTests.swift`.

The rest of the DST and midnight handling checks out: `DayKey.days` steps by calendar day
(`SheetsLogic.swift:142-151`), statistics collections anchor at local `startOfDay` with
`DateComponents(day: 1)` (`DailySummaryBuilder.swift:313-318`), and the Supabase hourly totals use UTC
hour boundaries (`HealthKitManager.swift:754-763`), so half-hour zones and the repeated fall-back hour
cannot produce two rows for one hour. `RefusedHourLedger` also counts UTC hours, which matches.

### I9 (Low). Data arriving more than two days late never reaches the sheet

An incremental pass starts at `lastWrittenDay - overlapDays` (2) (`SheetsSync.swift:177`, `:268`), and
recent workouts are merged from that same start (`:336`). Sleep stages use 7 days
(`SheetsSync+SleepStages.swift:12`), for exactly this reason. Failure scenario: a Garmin or Oura user
is away for four days and their app syncs into Health on return. The Daily rows for days 3 and 4 keep
the partial values already written, and workouts from those days are never added to the Workouts tab,
until a history rebuild happens to run. Proposed fix: widen `overlapDays` to 7 to match sleep (the
re-read is cheap: a week of statistics queries and an idempotent rewrite), or at least merge workouts
over 7 days.

### I10 (Low). Keychain save fails silently

`CredentialKeychain.save` (`ContentView.swift:122-140`) deletes the item and then ignores the
`SecItemAdd` status. If the add fails, the old value is already gone and the caller is not told.
For the Google refresh token, `exchange` (`GoogleAuth.swift:113`) then reports a successful sign-in,
and the next pass says "Not connected to Google". Proposed fix: use `SecItemUpdate` when the item
exists and `SecItemAdd` otherwise, return or throw the status, and have `exchange` fail on it, as
`AuthManager.saveToKeychain` already does (`AuthManager.swift:286-289`).

### I11 (Info). Logging and analytics in the app

- No analytics, crash-reporting or tracking SDKs in `ios/` (no Firebase, Sentry, Crashlytics,
  PostHog, etc.). The in-app privacy copy (`PrivacyView.swift:88-114`, `OnboardingView.swift:119`)
  matches.
- No health values are logged. Server error bodies and the Google token error are logged
  `.private` (`SheetsClient.swift:194`, `GoogleAuth.swift:181`). `print()` calls log type identifiers,
  counts and error enums only.
- Logged `.public`, metadata rather than values: each type's oldest sample date
  (`DailySummaryBuilder.swift:160`), refused day keys (`:323`), the access-limit day and
  `lastWrittenDay` (`SheetsSink.swift:154`, `:186`). The dates show when someone started tracking a
  type, but they reach only a sysdiagnose. Consider `.private` for the sample date at line 160 for
  consistency with `:204`.

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

## Verification run in this session

- `cd web && npm ci && npm run build` (includes the postbuild tests): exit 0, 12/12 performance tests
  and 34/34 agent-readiness tests pass after the fix.
- New test failed before the fix: `not ok 1 - legacy-setup banner names both destinations the app
  writes to`, `error: 'banner must not say Supabase is the only destination'`.
- Swift: not built, not tested (no toolchain in the sandbox).
