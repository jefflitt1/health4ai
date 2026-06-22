# health4ai — TestFlight & App Store Submission Checklist

Generated: 2026-06-22. All scripted steps already done. Follow these in order.

---

## DONE (scripted — no action needed)
- [x] PrivacyInfo.xcprivacy created and wired into Xcode build target
- [x] Team ID unified to Z3D54X3D96 (paid App Store account) across all build configs
- [x] Privacy Policy live at https://health4.ai/privacy
- [x] Committed: e056df9, c6c6ac1

---

## STEP 1 — Create App in App Store Connect (10 min, browser)

1. Go to https://appstoreconnect.apple.com
2. Sign in with jglittell@gmail.com
3. My Apps → "+" → New App
4. Fill in:
   - Platform: iOS
   - Name: **health4ai**
   - Primary Language: English (U.S.)
   - Bundle ID: **com.jglittell.health4ai** (register it first if not listed — see Step 1b)
   - SKU: **health4ai-001**
5. Click Create

### Step 1b — Register Bundle ID (if not listed in dropdown)
1. developer.apple.com → Certificates, Identifiers & Profiles → Identifiers → "+"
2. App IDs → App → Continue
3. Description: health4ai
4. Bundle ID: Explicit → **com.jglittell.health4ai**
5. Capabilities: check **HealthKit**
6. Continue → Register

---

## STEP 2 — Fill App Store listing metadata

In ASC → App Store → App Information + Version Information, paste:

**Subtitle:** Your health data, your database

**Description:**
health4ai syncs your Apple Health data directly to a Postgres database you own and control — no middleman, no subscription, no lock-in.

**How it works**
Connect your Supabase project (or any compatible Postgres endpoint), grant HealthKit read access, and health4ai syncs every data type in your Apple Health library — heart rate, HRV, sleep, workouts, steps, glucose, and more — into your own database. You query it, export it, build on it, however you like.

**Your data stays yours**
- health4ai never sees or stores your health data on its own servers
- All sync is device-to-your-database
- Revoke access anytime in iPhone Settings → Privacy & Security → Health

**Built for AI workflows**
Pair with the health4ai MCP server to give Claude, ChatGPT, or any AI assistant direct, structured access to your personal health history. Ask real questions about your real data.

**No account required**
Bring your own backend. Works with Supabase, custom REST endpoints, or any Postgres-compatible API. Full control from day one.

**Keywords:** health data,HealthKit,Supabase,AI health,health export,personal health,health sync,HRV,sleep data

**Support URL:** https://health4.ai
**Privacy Policy URL:** https://health4.ai/privacy
**Category:** Health & Fitness
**Price:** Free
**Age Rating:** 4+

**Review Notes:**
health4ai requires HealthKit access to read Apple Health data and sync it to a user-configured Postgres database endpoint. The app does not write health data. To test, the reviewer can configure any Supabase project (free tier at supabase.com) — detailed setup is shown in the onboarding flow. No special test credentials are needed.

---

## STEP 3 — Screenshots (required for App Store, NOT required for TestFlight internal)

Minimum required sizes:
- iPhone 6.7" (iPhone 15 Pro Max): 1290 × 2796 px — **required**
- iPad Pro 12.9" (6th gen): 2048 × 2732 px — required if iPad supported

Take screenshots on your iPhone after setup (Settings → Developer → Screenshots, or use Simulator).
Suggested screens: Home/dashboard, Onboarding, Connection setup, Sync progress.

**Skip screenshots for now if you just want TestFlight. Add before submitting for App Store Review.**

---

## STEP 4 — Archive and Upload in Xcode (15 min)

1. Open `~/ventures/health4ai/ios/Health4AI.xcodeproj` in Xcode
2. Set scheme: **Health4AI** (top bar)
3. Set destination: **Any iOS Device (arm64)** — NOT a simulator
4. Menu: **Product → Archive**
   - Wait for build to complete (~2–3 min)
5. Organizer opens automatically → select the new archive
6. Click **Distribute App**
7. Select **App Store Connect** → Next
8. Select **Upload** → Next
9. Leave all checkboxes default → Next
10. Sign in if prompted → Upload
11. Wait for processing in ASC (~5–20 min after upload)

**If Xcode says "No accounts" or "Team not found":**
- Xcode → Preferences → Accounts → Add Apple ID → jglittell@gmail.com

---

## STEP 5 — Enable TestFlight Internal Testing

1. ASC → TestFlight → Internal Testing → "+"
2. Select the build (once processing completes)
3. Add tester: jglittell@gmail.com (yourself)
4. Submit for Review (TestFlight internal review is usually same-day)
5. Once approved: open TestFlight app on iPhone → Install

**Result:** 90-day build. No more 7-day renewals.

---

## KNOWN GAP — Re-enable after iOS 26 stable

Background delivery (`com.apple.developer.healthkit.background-delivery`) is
disabled in Health4AI.entitlements due to iOS 26 Beta XPC crash. Re-enable
when stable iOS 26 ships:

1. `ios/Health4AI/Health4AI.entitlements` → add:
   `<key>com.apple.developer.healthkit.background-delivery</key><true/>`
2. `ios/Health4AI/Info.plist` → restore UIBackgroundModes + BGTaskSchedulerPermittedIdentifiers
3. Test on stable device, re-archive, upload new build

