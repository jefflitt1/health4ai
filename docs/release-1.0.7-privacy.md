# 1.0.7 privacy declaration decision (2026-11-16)

Scope: new Netlify destination, workout-event metadata and alcohol quantity export.
Existing source declarations include Health and Fitness, App Functionality, no
tracking, but linked=false. The public App Store label says linked. This is a
consistency defect.

## Evidence-supported correction

Retain the existing collection classification and set both declared categories'
`NSPrivacyCollectedDataTypeLinked` to true. Supabase exports carry user_id;
Google Sheets exports use the signed-in Google account; Netlify exports carry an
owner/person_id associated with device keys. These are persistent account/device
associations, not de-identification. A UUID or key hash does not make health rows
anonymous. Keep App Functionality purpose and tracking=false. This decision does
not assert that health4ai operates a shared health-data backend.

Apple defines linking through account, device or other identity details and
requires protections before collection to support a not-linked answer. Its
collection definition covers retained access by developer/partners. See
[Apple App Privacy Details](https://developer.apple.com/app-store/app-privacy-details/),
Data collection and Data linked to the user (checked 2026-11-16).
The [public label](https://apps.apple.com/us/app/health4ai/id6783074944)
declares Health/Fitness linked for App Functionality (checked 2026-11-16).

This does not change the classification to Data Not Collected. A future change
needs a separate assessment of independently owned destinations, developer/partner
access, account identifiers, and support or Apple diagnostics. Native API use and
absence of an analytics SDK alone do not settle those questions. Do not add
speculative collection categories.

## Release checks

- Read back actual App Store Connect privacy answers; the public label is not
  the complete console record.
- Inspect the signed release archive's manifest/privacy report after correction,
  confirming linked values and existing purpose/no-tracking settings.
- Publish and verify the policy's Netlify/REST destination inventory and
  explanation that key revocation does not erase retained health records.
- In-app privacy text already distinguishes Netlify from a shared health4ai
  backend. Website analytics remain separate from iOS health sync.
- Preserve physical-device acceptance gates in protected-data-sync.md and
  workout-export.md; simulator tests do not prove protected Health availability.

This review does not establish every jurisdiction's applicability, provider
contract terms, or the full developer diagnostics inventory. JGLV's product
legal/privacy checklist requires explicit unknowns scoped to dependent changes;
this is not a blanket compliance claim.
