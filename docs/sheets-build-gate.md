# Google Sheets build gate (compile-time)

The Google Sheets destination is compiled in only when the Swift condition `H4A_SHEETS` is set.

**Since 1.0.1 (Jeff 2026-10-02) Sheets ships in every build**, App Store included: the Google OAuth app was
published to production and its branding verified on 2026-09-30, so App Review and users no longer hit
"Access blocked" or the 7-day test-user token limit.

| Build | `H4A_SHEETS` | Sheets reachable |
|-------|--------------|------------------|
| Debug (Xcode, simulator) | on | yes |
| Release (Xcode Cloud, TestFlight, App Store) | on (`H4A_RELEASE_CONDITIONS = "H4A_SHEETS"`) | yes |

The condition is kept, rather than deleted, so a build without Sheets stays one setting away
(`H4A_RELEASE_CONDITIONS = ""`) if Google access ever has to be pulled; the CI gates below would then need the
inverse check again (see git history before 2026-10-02 for that version).

What the flag controls: `GoogleAuth`, `SheetsClient`, `SheetsSink`, `SheetsLogic`,
`DailySummaryBuilder`, `SheetsDestinationView` (picker, connect section, Home card), the Sheets branches in
`HomeView`, `ConnectionView`, `PrivacyView`, `SyncEngine`, `AppDelegate`, and `ConnectionType.googleSheets`.
`Info.plist` has no `CFBundleURLTypes`: the OAuth redirect is handled in-process by `ASWebAuthenticationSession`,
so there is no URL scheme to keep or remove.

## If Sheets is ever compiled out again (stored Sheets choice)

With the case gone, `ConnectionType(rawValue: "googleSheets")` is nil, so `SyncState.init` (a) coerces to
`.supabase` and writes that back to UserDefaults, and (b) resets `lastSyncDate`, `lastSyncRecordCount`,
`lifetimeSyncedRecords` and clears Sync History, because Sheets passes wrote those same values and the database
Home ("has synced once") and the App Store review prompt read them. The Supabase session is not touched: choosing
Sheets in the picker already signed it out, so the phone shows the signed-out "Connect Your Database" Home.

Left on the device deliberately: the Keychain key `hkb.googleRefreshToken` (its literal stays in every build, in
`CredentialKeychain.sensitiveKeys`) and the UserDefaults key `hkb.sheetsDestination` (sheet id and URL). Erase Local
Data & Configuration removes both (`deleteAll()` and the `hkb.` prefix sweep). A later Sheets-enabled build finds
them and the person is still signed in.

## Enforcement (fail closed)

- `ci_pre_xcodebuild.sh`: exits 67 if the committed `H4A_RELEASE_CONDITIONS` is not `"H4A_SHEETS"`.
- `ci_post_xcodebuild.sh`: on the archive action (`CI_XCODEBUILD_ACTION`, `CI_ARCHIVE_PATH`) it greps the app for
  `sheets.googleapis.com` and exits 73 if absent. Missing archive: exit 70/71. Other actions are skipped.
- `H4A_ENABLE_SHEETS` is no longer read; a leftover workflow variable has no effect.

Local check: `H4A_PBXPROJ=<copy of project.pbxproj> ios/ci_scripts/ci_pre_xcodebuild.sh`.
The off-device tests compile `SheetsLogic.swift` with `-D H4A_SHEETS`: `ios/scripts/test_sheets_logic.sh`.

## Other pipelines

`.github/workflows/testflight.yml` archives Release with plain `xcodebuild archive`; it reads the committed
setting, so it also builds WITH Sheets.

## Screenshots and demo video

Use a Release build (TestFlight from main): it now shows the Sheets picker and Home card, which App Review needs
to see in the demo video.
