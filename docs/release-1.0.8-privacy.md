# 1.0.8 privacy declaration (2026-11-20)

1.0.8 is the first App Store build containing the opt-in workout detail and GPS
route export (#70, `fd4fc4e`). Submitted 1.0.7 build 84 was cut from `fa5be1a`,
before it (`git merge-base --is-ancestor fd4fc4e fa5be1a` is false, verified
2026-11-20).

## What changed in the binary since 1.0.7

- `PrivacyInfo.xcprivacy` declares `NSPrivacyCollectedDataTypePreciseLocation`:
  linked, not tracking, App Functionality. Same basis as the 1.0.7 decision in
  `release-1.0.7-privacy.md`: exports carry the user's account id, so they are
  linked.
- `NSHealthShareUsageDescription` names the separate route export and precise
  locations.
- Both exports are off by default, each needs its own switch, and nothing is sent
  until the user picks a workout and an export action. Records go to the user's
  own Supabase project.

## Required before submission

1. App Store Connect, App Privacy: add **Precise Location**, linked to the user,
   not used for tracking, purpose App Functionality. Read back the saved answers;
   the public label is not the full console record.
2. Inspect the signed 1.0.8 archive's privacy manifest and report (Precise
   Location, Health, Fitness all linked, no tracking).
3. Privacy policy: the workout/route item still says "planned for a later
   release". Its update (UX gate approved 2026-11-20) is held for release day,
   because merging `web/` publishes at once: apply
   `~/review/health4ai-release-1-0-8/privacy-page-1.0.8-on-release.patch` in its
   own PR when 1.0.8 goes live.
4. Review notes: say both exports are off by default and how a reviewer reaches
   them (Privacy, Optional workout details). The physical-device demo video should
   show the switches and their consent text.

1.0.8 also carries #74 (GitHub #71), which adds no collection.
