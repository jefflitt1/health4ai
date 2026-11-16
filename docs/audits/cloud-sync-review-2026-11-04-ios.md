# iOS findings appendix — November 4, 2026 audit

Historical findings from the [main review](cloud-sync-review-2026-11-04.md).
Read its current-status reconciliation before treating any finding as open.
Original file/line references and proposed fixes are retained as review evidence.

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

