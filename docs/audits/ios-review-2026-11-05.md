# iOS review, 2026-11-05

Scope: `ios/Health4AI` (all Swift, Info.plist, entitlements, privacy manifest), checked against `web/src/pages/privacy.astro`. This was a read-only review. No Swift toolchain was available in the review environment (Linux, no `swiftc`, no Docker daemon). Nothing below was compiled or run, including `ios/scripts/test_sheets_logic.sh`, which needs `xcrun`. Every fix in this branch needs an Xcode build and a device pass before merge.

Severity reflects user impact (lost or duplicated data, privacy, App Review) times likelihood.

Status update 2026-11-09: the five fixes first proposed in PR #43, plus H1 and the H2 remainder, shipped in #51 (iOS 1.0.6). Their status lines below say so. Every other item is unchanged since the review.

## Architecture map

- **Authorization.** `HealthKitManager.requestAuthorization(scope:adding:)` asks for read access to the chosen scope: essentials, or complete (about 120 types). The scope is persisted only after the request succeeds. Sheets adds `DailySummaryBuilder.readTypes` on top, and `statusForAuthorizationRequest` gates each Sheets pass (`SheetsError.healthNotAsked`). On iOS 27, a limited-history grant is detected with `earliestAuthorizedSampleDate` (`historyAccessLimit`). The bike import is the only writer to Health, with share access for five core types plus heart rate.
- **Queries.**
  - Live sync uses `HKAnchoredObjectQuery`, paged at 5,000 (`SyncEngine.queryAnchoredSamples`) and bounded by the import-horizon floor.
  - Backfill uses `HKSampleQuery` over 90-day `.strictStartDate` chunks with per-chunk checkpoints (`BulkExportManager.backfillType`).
  - Double-counted activity types are sent as merged UTC-hour totals from `HKStatisticsCollectionQuery` (`HealthKitManager.hourlyTotals`). Refused ranges are split with `RangeSplit`, and the refused hours go into the `RefusedHours` ledger.
  - Sheets builds daily rows from `HKStatisticsCollectionQueryDescriptor` with local-midnight anchors. Sleep is a union over noon-to-noon windows (`SleepMath`).
- **Background.**
  - One `HKObserverQuery` runs per type, plus a separate workout observer, with `enableBackgroundDelivery(.immediate)`.
  - A `BGAppRefreshTask` (`com.health4ai.sync`) refires about hourly.
  - A charger-only `BGProcessingTask` (`com.health4ai.backfill`) runs the import.
  - Scene-phase routing lives in `AppLifecycle`; app-delegate lifecycle callbacks never fire.
- **Concurrency.** `SyncMutex` serializes per-type syncs and the anchor dictionary. `fullSyncInFlight` (MainActor) collapses concurrent full passes. The backfill runs in its own `Task`, separate from the mutex.
- **Destinations.**
  - Supabase/REST: JSON `POST {samples:[...]}` in batches of 500 to the user's `healthkit-ingest` function, with a Bearer JWT. A capability probe (`merged_hours_v1`) gates merged hours.
  - Google Sheets: Sheets API v4 directly from the phone, scope `drive.file` (`SheetsClient`, `SheetsSyncCore`).
  - No health4ai server sits on either path. `cloudflare/api-proxy` is not referenced by the app.
- **Tokens.**
  - The Supabase access and refresh tokens are in the Keychain (`com.healthkitbridge.auth`, `AfterFirstUnlockThisDeviceOnly`).
  - The anon key, REST secrets and Google refresh token are in the Keychain (`com.healthkitbridge.credentials`).
  - The Google access token is kept in memory only.
  - The expiry cache and all non-secret state are in UserDefaults (`hkb.*`, `h4a.bike.*`).
- **Retry.**
  - `postSamples`: 3 attempts, 1s and 2s backoff, retries 429/5xx/network errors.
  - `SheetsClient.send`: one forced token refresh on 401, then up to 3 backoff retries on 429/5xx.
  - The backfill retries a failed type on the next run.
  - A refused hour or day is retried on later passes.
- **Error surfacing.**
  - Full-pass outcomes go to `SyncState` (`recordSyncError`, `recordSyncPartial`) and to `SyncHistoryStore` (last 50 entries).
  - Things only the person can fix go to `SheetsAttention`.
  - Import problems go to `emptyExpectedMetricNames`, `importFailedMetricNames` and `refusedHourMetricNames`.
  - Bike results go to `BikeImportResult`.

## Findings, ranked

Status: **FIXED** means the fix is on main (shipped in #51). **OPEN** means it is reported only.

### High

**H1. Bike import can duplicate Active Energy and Cycling Distance after a failed or unconfirmed save.** FIXED in #51 (each sample now carries the ride id, and leftovers from a failed save are deleted by ride id before a retry)
- Where: `BikeImport/HealthKitBikeStore.swift:66-96`, `BikeImport/BikeSaveConfirmation.swift:30-44`.
- Only the workout carries `HKMetadataKeySyncIdentifier`; the per-bucket quantity samples carry no metadata. `HKWorkoutBuilder` saves samples as they are added, and `discardWorkout()` does not delete them (the code's own header note says so).
- Scenario: `addSamples` succeeds, then `endCollection` throws, or `finishWorkout` returns nil and the lookup misses. The ride is reported failed or unconfirmed, and the next import adds every sample again, so the day's energy and distance totals double. The same happens when a person deletes only the workout in Health, which the copy says re-imports the ride.
- Fix: give each sample its own sync identifier (`"<ride sync id>:<type>:<bucket>"`) plus `HKMetadataKeySyncVersion`, so a re-save replaces instead of adding. Alternatively, before retrying a ride, delete this app's samples in the ride's window. Needs a device test.

**H2. Erase Local Data left sync history and device names behind.** FIXED in #51
- Where: `SyncState.swift:494`, `ConnectionView.swift:97-107`.
- The dialog promises to remove sync history. The function swept only `hkb.` defaults and the Keychain, so `sync-history.json` and `sources.json` survived. `sources.json` holds names such as "Jeff's Apple Watch" with sample counts.
- Fix: call `SyncHistoryStore.shared.removeAll()`, plus a new `SourcesTracker.removeAll()`.
- Also fixed in #51 (`BikeImportCoordinator.eraseAll()`). As originally reported: the `h4a.bike.*` keys (bike address, last result, rejected set, enabled flag) and the in-memory `BikeImportCoordinator.isEnabled`. After an erase, the next foreground still imports rides into Health. Fix: remove `h4a.` keys in the same loop and `await BikeImportCoordinator.shared.setEnabled(false)` from the erase button's action.

### Medium

**M1. Observer queries leaked, and the workout observer survived sign-out.** FIXED in #51
- Where: `SyncEngine.swift:269-395`.
- `startObserving` executed new `HKObserverQuery`s on every call and only replaced the dictionary entry. It is called from launch, from sign-in (`ContentView.swift:313`) and from the Sheets connect flow (`SheetsDestinationView.swift:215`), so earlier queries kept running.
- `registerWorkoutObserver`'s query was never stored, so `stopObserving` never stopped it. After sign-out or a destination switch, every workout fired a sync that failed with "Auth failed" and was logged to Sync History.
- Fix: `startObserving` calls `stopObserving` first, and the workout query is tracked.
- Remaining note: the workout type is also in every scope's per-type observers, so each workout triggers two (serialized) syncs. The second finds an empty page. Removing the extra observer is a follow-up once someone confirms nothing depends on its "Workouts" history label.

**M2. Concurrent Supabase token refreshes.** FIXED in #51
- Where: `AuthManager.swift:253`.
- At launch, `reconnectIfAuthenticated` starts the foreground sync and then `applyMergedHoursResendIfNeeded`; the backfill calls `validToken` too, outside the sync mutex. After an hour away all of them find the token expired and refresh with the same rotating refresh token. Supabase allows reuse only inside its reuse interval (10s by default); a slow network or a stricter project config revokes the session family and signs the person out.
- Fix: share one in-flight refresh `Task` (MainActor-isolated).

**M3. HealthKit purpose string does not mention Google Sheets.** OPEN (copy decision)
- Where: `Info.plist` `NSHealthShareUsageDescription`.
- "to sync them to the backend you configure" is accurate for the database path, but Google Sheets is the default destination for new installs. Guideline 5.1.1 asks purpose strings to say clearly where data goes.
- Suggested: "health4ai reads only the Health data you allow, to save it to the destination you choose: your own Google Sheet or your own database."

**M4. Privacy policy omits the bike import (writing to Apple Health, local-network access).** OPEN
- Where: `web/src/pages/privacy.astro`.
- The policy describes only data leaving the phone. The app also writes workouts, energy, distance, power, cadence and heart rate to Health (`NSHealthUpdateUsageDescription`) and reads rides from a host on the local network. HealthKit apps that write data should say so (5.1.3).
- Fix: add a short section, e.g. "Bike on your network: optional; reads rides from a device on your Wi-Fi and saves them to Apple Health on your phone; nothing is sent to health4.ai."

**M5. A Supabase password and JWT can go over cleartext HTTP to a local host.** OPEN
- Where: `AuthManager.swift:143-166`, `SyncState.resolvedEndpointURL`, `Info.plist` `NSAllowsLocalNetworking`.
- ATS allows plain HTTP to `.local` and IP-literal hosts for the bike, and the Supabase path keeps whatever scheme was typed. A self-hosted `http://192.168.1.10:8000` therefore sends the password, the Bearer token and health samples in the clear on the Wi-Fi. The `https` check exists only for the checklist tick (`ConnectionView.swift:335`).
- Fix: refuse a non-`https` scheme for the Supabase project URL in `signIn`, `refreshAccessToken` and `postSamples` (throw `invalidURL`).

**M6. A ride imported while still being written is truncated for good.** OPEN (plausible)
- Where: `BikeImport/BikeImporter.swift:212`, with `liveWindow` at :229 used only for rejections.
- If the bike lists a ride that is still in progress, it imports with partial length and calories, and its sync identifier then makes every later import count it as already imported.
- Fix: skip candidates whose `start + elapsed > now - liveWindow`, and add a note saying they will import next time. Confirm against the bike's behaviour first.

**M7. Sheets creation can leave orphan spreadsheets in Drive.** OPEN
- Where: `SheetsSink.swift:452-466`.
- `createSpreadsheet` succeeds, then `writeRanges` for the headers throws (network, quota). The state is saved only after both, so the next pass creates another "health4ai" spreadsheet, and repeated failures leave several.
- Fix: save the state right after create, with a `headersWritten` flag that the next pass completes before syncing.

**M8. Backfill memory on dense histories.** OPEN
- Where: `BulkExportManager.swift:566-575`.
- Each 90-day chunk is an `HKSampleQuery` with `HKObjectQueryNoLimit`. For heart rate on a Watch with many recorded workouts (about 1 Hz during workouts), one chunk can hold hundreds of thousands of `HKSample`s plus their `HealthSample` copies and JSON, which risks a jetsam kill. The checkpoint resumes, but the same chunk is retried and may die again.
- Fix: page within the chunk (an anchored query with `limit`, or shrink `chunkDays` adaptively when a chunk returns more than about 50k samples).

**M9. Merged hourly totals misattribute day boundaries in half-hour zones.** OPEN (documented trade-off)
- Where: `HealthKitManager.swift:754-763`.
- UTC hours keep the upsert key stable, but in India (+5:30), Newfoundland, Iran, Nepal, central Australia and similar zones, a local midnight falls mid-hour. The straddling hour's whole total lands on one day, so daily step and energy sums are off by up to one hour's activity at each boundary.
- Fix, if it matters to users there: split the boundary hour into two half-hour rows only for those zones, or document the limitation on the setup page.

### Low

**L1. 4xx ingest responses were retried three times.** FIXED in #51
- Where: `SyncEngine.swift:885-895`.
- The 4xx branch threw `SyncError.httpError` inside the `do`, and the `catch let syncError as SyncError` swallowed it and looped. A 400 or 413 cost three posts and 3s of backoff, against the comment's intent.

**L2. The Supabase auth URL dropped the port.** FIXED in #51
- Where: `AuthManager.swift:117`.
- Sign-in and refresh went to `scheme://host`, while ingest went to `scheme://host:port`.

**L3. Backfill task handle race.** OPEN
- Where: `BulkExportManager.swift:311-333`.
- The run `Task` ends with `self.currentTask = nil` off the main actor. After `cancelBackfill()` (HomeView, `resetBackfill`, BG expiration) and a quick `startBackfill()`, the old run's trailing assignment clears the new run's handle, so a third start passes the guard and two runs overlap. They read-modify-write `completedTypes`.
- Fix: make `startBackfill`, `cancelBackfill` and `currentTask` `@MainActor`, and clear the handle only if it is still the same run (compare a run UUID).

**L4. Keychain write failures are silent.** OPEN
- Where: `ContentView.swift:122-139` (`CredentialKeychain.save`).
- It deletes, then ignores the `SecItemAdd` status. A failed add erases the anon key or the Google refresh token while the UI shows success. For Google, `exchange` returns normally and `isSignedIn` is false on the next pass.
- Fix: return or throw the `OSStatus`; use `SecItemUpdate` with `SecItemAdd` as the fallback.

**L5. `try?` swallows the HealthKit authorization error after Supabase sign-in.** OPEN
- Where: `ContentView.swift:312`.
- Sync starts anyway and fails per type with "Authorization not determined". Show the error, as the Sheets flow does.

**L6. Persisted state decodes with `try?`, so a schema mismatch silently resets.** OPEN
- Where: `SheetsDestinationState.load` (`SheetsSink.swift:234`) and `HistoryFound.load`.
- An undecodable `hkb.sheetsDestination` (for example a future non-optional field) returns nil, and the next pass creates a brand-new spreadsheet with no notice.
- Fix: log at error level and keep the blob aside, as `RefusedHours.load` already does.

**L7. Background delivery stays enabled after sign-out.** OPEN
- Where: `SyncEngine.stopObserving`.
- The observers stop, but `disableAllBackgroundDelivery` is never called, so iOS keeps waking the app for nothing.

**L8. Health-adjacent values logged as public.** OPEN
- Where: `BikeImportCoordinator.swift:147-150`, `BikeImporter.swift:198,209`, `BikeClient.swift:70`, `DailySummaryBuilder.swift:160`.
- Logged as public: ride IDs (exact workout start times), validation reasons with heart-rate and calorie values, and the oldest-sample dates per type. These end up in sysdiagnoses people send to support.
- Fix: use `.private` (or `.private(mask: .hash)`) for IDs, dates and reasons.

**L9. Tokens survive app deletion.** OPEN
- Keychain items persist across delete and reinstall, while UserDefaults does not. A reinstall (fresh install, so it defaults to Sheets mode) finds the old Google refresh token, reports signed in, and creates a new sheet with no consent screen.
- Fix: on a launch with no `hkb.` install marker, wipe both Keychain services before reading them. Add the marker in a release first, so existing installs are not wiped on upgrade.

**L10. Bike: turning Import off does not stop a running import.** OPEN
- Where: `BikeImportCoordinator.swift:69-72`; `BikeImporter.run` never checks for cancellation.

**L11. Anchored paging can stop early.** OPEN
- Where: `SyncEngine.swift:703`.
- The query `limit` counts deleted objects as well as added samples, so a page with deletions returns fewer than 5,000 samples while more remain. The loop breaks, and the rest waits for the next observer fire or refresh task. Nothing is lost.

**L12. `cloudflare/api-proxy` routes to the maintainer's own Supabase project.** OPEN
- The app does not use it. If any client ever did, health data would reach a health4.ai-operated backend, which contradicts "we never receive your health data". Delete it or mark it unused in its README.

**L13. "Your Sources" sample counts inflate on every re-import.** OPEN (cosmetic)
- Where: `SourcesTracker.swift:71`.

## Checked, no defect found

- Unit mapping (`HealthKitManager.unitMap`): explicit nutrition units, and the effort-score special case. Sheets units are fixed at sheet creation.
- Day iteration steps by calendar day (DST-safe). The noon-to-noon sleep window is built with `bySettingHour`. Sheets serial dates are read unformatted.
- An empty first chunk is skipped, not failed, and an empty whole history raises `noHealthData` instead of reporting success.
- Anchors advance only after a page posts. The backfill checkpoint advances only after every batch in the chunk posts. Cancellation is rethrown rather than read as completion.
- Refused statistics ranges are split down to single hours or days and retried later; nothing posts a zero for a refused hour.
- Google OAuth: PKCE S256, state checked, `drive.file` only, refresh token in the Keychain, access token in memory, revoke on disconnect.
- No analytics or crash SDKs in the app; the privacy manifest declares Health and Fitness, not linked, not tracking.

## Fixes

All of these shipped in #51 (iOS 1.0.6), which also covers H1 and the H2 remainder:
- `postSamples` no longer retries 4xx.
- `startObserving` is idempotent; the workout observer is tracked and stopped.
- The Supabase auth URL keeps the port.
- Concurrent callers share one Supabase token refresh.
- Erase removes the sync history and the sources list, and turns the bike import off.
