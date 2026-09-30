# Google Sheets build gate (compile-time)

The Google Sheets destination is compiled in only when the Swift condition `H4A_SHEETS` is set.

| Build | `H4A_SHEETS` | Sheets reachable |
|-------|--------------|------------------|
| Debug (Xcode, simulator) | on | yes |
| Release from main (App Store) | off | no: the code, strings and Google endpoints are not in the binary |
| Release with `H4A_ENABLE_SHEETS=1` (TestFlight) | on | yes |

Why compile-time: the old runtime check (`appStoreReceiptURL == "sandboxReceipt"`) is also true for App Review
builds, so a reviewer would have reached Google sign-in and hit "Access blocked" (OAuth consent screen is in Testing).

What is compiled out without the flag: `GoogleAuth`, `SheetsClient`, `SheetsSink`, `SheetsLogic`,
`DailySummaryBuilder`, `SheetsDestinationView` (picker, connect section, Home card), the Sheets branches in
`HomeView`, `ConnectionView`, `PrivacyView`, `SyncEngine`, `AppDelegate`, and `ConnectionType.googleSheets`.
`Info.plist` has no `CFBundleURLTypes`: the OAuth redirect is handled in-process by `ASWebAuthenticationSession`,
so there is no URL scheme to keep or remove.

## Existing testers (stored Sheets choice)

With the case gone, `ConnectionType(rawValue: "googleSheets")` is nil, so `SyncState.init` (a) coerces to
`.supabase` and writes that back to UserDefaults, and (b) resets `lastSyncDate`, `lastSyncRecordCount`,
`lifetimeSyncedRecords` and clears Sync History, because Sheets passes wrote those same values and the database
Home ("has synced once") and the App Store review prompt read them. The Supabase session is not touched: choosing
Sheets in the picker already signed it out, so the phone shows the signed-out "Connect Your Database" Home.

Left on the device deliberately: the Keychain key `hkb.googleRefreshToken` (its literal stays in every build, in
`CredentialKeychain.sensitiveKeys`) and the UserDefaults key `hkb.sheetsDestination` (sheet id and URL). Erase Local
Data & Configuration removes both (`deleteAll()` and the `hkb.` prefix sweep). A later Sheets-enabled build finds
them and the person is still signed in.

## Producing a TestFlight build WITH Sheets (Jeff, App Store Connect UI)

`ios/ci_scripts/ci_pre_xcodebuild.sh` flips the Release condition when `H4A_ENABLE_SHEETS=1`.

1. App Store Connect > Xcode Cloud > Manage Workflows > New Workflow (name it "TestFlight with Sheets").
2. Start condition: a branch you choose (for example `testflight-sheets`), never main. Changes to `ios/` only.
3. Environment: Archive iOS, scheme `Health4AI`, Release. Add environment variable `H4A_ENABLE_SHEETS` = `1`.
4. Post-action: TestFlight Internal Testing only.
5. The default App Store workflow on main must NOT define `H4A_ENABLE_SHEETS`. Unset means Sheets is compiled out.
6. Check the build log for "H4A_ENABLE_SHEETS=1: building WITH Google Sheets". Any other value fails the build.

Local check of the script: `H4A_ENABLE_SHEETS=1 H4A_PBXPROJ=<copy of project.pbxproj> ios/ci_scripts/ci_pre_xcodebuild.sh`.

The off-device tests compile `SheetsLogic.swift` with `-D H4A_SHEETS`: `ios/scripts/test_sheets_logic.sh`.

## Enforcement (fail closed)

- `ci_pre_xcodebuild.sh`: with `H4A_ENABLE_SHEETS` unset it exits 67 if the committed `H4A_RELEASE_CONDITIONS` is
  not `""`.
- `ci_post_xcodebuild.sh`: on the archive action (`CI_XCODEBUILD_ACTION`, `CI_ARCHIVE_PATH`) it greps the app for
  `sheets.googleapis.com`. Unset flag and found: exit 72. Flag `1` and not found: exit 73. Missing archive: exit 70/71.
  Other actions are skipped.

## Other pipelines

`.github/workflows/testflight.yml` archives Release with plain `xcodebuild archive` and does not run these scripts,
so it always builds WITHOUT Sheets. Only an Xcode Cloud workflow with `H4A_ENABLE_SHEETS=1` produces a Sheets build.

## Capturing 1.0.1 marketing screenshots

A normal Debug build compiles `H4A_SHEETS`, so its screens (and the DEBUG screenshot fixtures) show the Sheets
picker and Sheets Home card. For App Store screenshots or the demo video, use a Release build (TestFlight from
main), or Debug with `SWIFT_ACTIVE_COMPILATION_CONDITIONS=DEBUG`, which runs the same no-Sheets code as Release.
(Sasha UX gate note, 2026-09-30.)
