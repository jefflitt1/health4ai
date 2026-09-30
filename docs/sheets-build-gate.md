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

With the case gone, `ConnectionType(rawValue: "googleSheets")` is nil, so `SyncState.init` coerces to `.supabase`
and writes that back to UserDefaults. The Google refresh token stays in the Keychain
(`hkb.googleRefreshToken`, unused) until the person taps the Device Privacy erase, which `deleteAll()` covers; a
later Sheets-enabled build finds it and they are still signed in.

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
