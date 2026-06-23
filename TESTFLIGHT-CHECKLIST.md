# health4ai — TestFlight Tester Checklist

Updated: 2026-06-23. All infrastructure work is done. Three manual steps remain.

---

## What's been done

- [x] PrivacyInfo.xcprivacy wired into Xcode build target
- [x] Team ID Z3D54X3D96 across all build configs
- [x] Privacy Policy live at https://health4.ai/privacy
- [x] App created in App Store Connect (com.jglittell.health4ai)
- [x] health4.ai cloud backend removed — app is self-hosted only (Supabase / REST)
- [x] Hosted-tier DB tables dropped from Supabase (healthkit_api_keys, healthkit_setup_codes)
- [x] Build number bumped to **1.0 (2)** for this upload

---

## STEP 1 — Archive and Upload (Xcode, ~15 min)

1. Open `~/ventures/health4ai/ios/Health4AI.xcodeproj`
2. Top bar: scheme **Health4AI**, destination **Any iOS Device (arm64)**
3. **Product → Archive** — wait ~2–3 min
4. Organizer opens → select the new archive → **Distribute App**
5. **App Store Connect → Upload** → leave all checkboxes default → Next → Upload
6. Wait for processing in App Store Connect (~5–20 min)

---

## STEP 2 — Add the Tester (App Store Connect, ~5 min)

1. https://appstoreconnect.apple.com → your app → **TestFlight**
2. **Internal Testing** → select the new build (1.0 build 2)
3. **Add Testers** → enter their Apple ID email
4. They get a TestFlight invite email; they install the TestFlight app and accept

> Internal testers don't need a review wait. External testers (non-Apple-ID-on-your-account) require a one-time Beta App Review (~24–48 hr). Add yourself first to confirm the build works, then add external testers.

---

## STEP 3 — What the Tester Sees

**Onboarding flow (3 steps):**
1. Welcome screen
2. Privacy explanation
3. HealthKit permission grant

**Connection screen:**
- Two backend options: **Supabase** (recommended) or **REST / Webhook**
- For Supabase: paste their project URL + anon key → Test Connection → done
- No health4.ai account, no setup code, no cloud option

**What they need before testing:**
- A free Supabase project (supabase.com) with the health4ai schema applied, OR
- Any HTTPS endpoint that accepts JSON POST

> You can send testers the setup SQL from `supabase/migrations/001_healthkit_schema.sql` — it's the only migration they need to run on their own Supabase project.

---

## KNOWN GAP — Background delivery (re-enable after iOS 26 stable)

`com.apple.developer.healthkit.background-delivery` is disabled due to iOS 26 Beta XPC crash.
When stable iOS 26 ships:
1. `ios/Health4AI/Health4AI.entitlements` → add `<key>com.apple.developer.healthkit.background-delivery</key><true/>`
2. `ios/Health4AI/Info.plist` → restore UIBackgroundModes + BGTaskSchedulerPermittedIdentifiers
3. Re-archive, bump build number, upload

---

## App Store listing metadata (for when you submit for public review)

**Subtitle:** Your health data, your database

**Description:**
health4ai syncs your Apple Health data directly to a Postgres database you own and control — no middleman, no subscription, no lock-in.

Connect your Supabase project (or any compatible Postgres endpoint), grant HealthKit read access, and health4ai syncs every data type in your Apple Health library — heart rate, HRV, sleep, workouts, steps, glucose, and more — into your own database.

**Your data stays yours**
- health4ai never sees or stores your health data
- All sync is device-to-your-database
- Revoke access anytime in iPhone Settings → Privacy & Security → Health

**Built for AI workflows**
Pair with the health4ai MCP server to give Claude, ChatGPT, or any AI assistant direct access to your personal health history.

**Keywords:** health data,HealthKit,Supabase,AI health,health export,personal health,health sync,HRV,sleep data
**Support URL:** https://health4.ai
**Privacy Policy URL:** https://health4.ai/privacy
**Category:** Health & Fitness | **Price:** Free | **Age Rating:** 4+

**Review Notes:**
health4ai requires HealthKit access to read Apple Health data and sync it to a user-configured Postgres database endpoint. The app does not write health data. To test, the reviewer can configure any Supabase project (free tier at supabase.com). No special test credentials are needed.
