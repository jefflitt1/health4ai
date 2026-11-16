# health4ai — design reference

**Owner:** Jess (JGLI) reviews, Sasha Kim gates. Created 2026-09-09 after the design gate
flagged twice that this repo carries a blocking review with no token document.

This describes what the app **actually does today**, verified against
`ios/Health4AI/HomeView.swift`. It is not aspirational. If a rule here disagrees with the
code, one of them is wrong — say which rather than quietly following the code.

## Colour

**Every colour is a SwiftUI system semantic. There are no raw hex values in the iOS app,
and none should be added.** That is what makes the app correct in light mode, dark mode
and increased-contrast for free.

| Role | Token | Used for |
|---|---|---|
| Page ground | `Color(.systemGroupedBackground)` | `ScrollView` background |
| Card ground | `Color(.secondarySystemGroupedBackground)` | every card |
| Primary text | `.primary` | headline + body |
| Secondary text | `.secondary` | captions, sublabels |
| Brand accent | `.pink` | the ONE prominent action per screen |
| Healthy | `.green` | connected, complete |
| Attention | `.orange` | partial data, server update needed, background sync unavailable, stalled import |
| Failure | `.red` | sync error, destructive rows |
| In progress | `.blue` | actively syncing |

### Two rules that have already been broken once each

1. **Orange and red are for symbols and fills, not for body text.** Measured 2026-09-09:
   orange caption text on the card ground is **2.31:1** in light mode, below even the 3:1
   large-text floor. Put the semantic on the icon and a 12% tint background; keep the
   words on `.primary`.
2. **`.pink` on `.borderedProminent` with white text is 3.52:1 and fails AA.** It is
   tolerated on the single genuine primary action per screen and nowhere else. Do not
   spread it, and do not use it for a secondary action to "keep things on brand".
3. **Tint a button. Never foreground-style one.** An explicit `.foregroundStyle`
   *anywhere* in a `Button`'s label subtree overrides SwiftUI's automatic disabled
   dimming, and the control then renders live while dead. Measured 2026-09-09: a
   `.disabled` row at `rgb(0,136,255)`, pixel-identical to the enabled row above it,
   against `rgb(197,197,199)` once switched to `.tint`. Moving the modifier from the
   Button onto its label does *not* help — the dimming is applied to that content.
   `.tint` composes; `.foregroundStyle` overrides. Prefer `.tint` over an explicit
   conditional colour too: a colour keyed off the same predicate as `.disabled(...)`
   is two sources asserting one fact, and they drift.

## Status colour is a single signal

`statusColor` in `HomeView.swift` is the one place that maps state to colour. The status
card's icon and border read from it; its title and caption stay `.primary` and `.secondary`
(rule 1 above). Precedence, highest first: syncing → error → **connected, deferred Health data** → **Sheets needs attention** →
**partial data** → **server update needed** → **background sync unavailable** → connection
health. Sheets needs attention (Google access removed, sheet missing, no Health data readable)
is a problem only the person can fix. It is never also recorded as `syncError`. The status card
shows only the headline "Needs attention" with an orange icon and border, and the Google Sheet
card owns the message and the one action that resolves it. Partial data,
server update needed and background sync unavailable are shown, and coloured, only while the
connection is healthy. Background sync unavailable means `enableBackgroundDelivery` failed for
at least one type on this device; the app still syncs on every open, so it is attention, not
failure.

Deferred Health data uses a neutral `.secondary` status border and a `.primary` lock symbol
and headline “Waiting for device unlock”. It appears only while authenticated and pending;
an existing sync error retains priority. Unlock/foreground retries the pending work.

**Never add a second, independent colour path for the same state.** The bug this ordering
exists to prevent: the headline said green "Active" while the card below it named four
metrics that had returned nothing.

A self-healing notice (the app retries and the person has nothing to do, such as HealthKit
refused hours, GitHub #28) uses a neutral `.secondary` symbol, never orange, and does not feed
`statusColor`. Orange means attention the person or the connection owes.

## Honest numbers

The app reports on data it does not own, so a number on screen is a claim.

- **Never render a value the server did not supply.** `postSamples` returns `Int?`; nil
  means the endpoint did not report, and nil must render as *absence of a line*, never
  as `0`. A definite zero is as much a fabrication as a definite success.
- **"Sent" and "stored" are different claims.** The ingest upserts, so a re-sweep posts
  hundreds of thousands of samples and stores none. Show the stored number first — it is
  the trustworthy one — and never collapse the pair into one figure.
- **A spinner is a claim too.** If nothing has moved, stop it. A spinner above the words
  "nothing has moved" is a contradiction, and the spinner wins.
- **"Filling…" under a switch.** When turning a switch on starts work (a Sheets tab being
  filled), a secondary line under the Toggle label says so, shown only while a sync that does
  that work is running. It goes when the sync ends or the switch goes off. Plain `Text`, so the
  Toggle gives it secondary styling; no spinner, no hand-set colour.
- **Green means verified, not attempted.** An operation that completed without evidence
  gets attention colour, not success colour.

## Buttons

- **One prominent action per card, maximum.** Prominence follows what the button does;
  a secondary action rendered full-width and tinted reads as an unresolved error on a
  healthy screen.
- **Destructive rows are `.red`,** and anything that discards work asks first with a
  `confirmationDialog` stating the cost in plain terms ("It can take hours").
- **Label the action, not the mechanism.** "Retry These Metrics" must retry exactly the
  metrics named above it — if the label says "these", passing a wider set is a lie.
- **A recovery instruction names a control that exists, is visible, and is enabled.**
  Prose pointing at a disabled button in another card is not a recovery path; put the
  button in the message.
- **44pt minimum** on every tap target.

## Type

System font throughout. `.largeTitle` nav title, `.headline` card titles, `.subheadline`
primary values, `.caption`/`.caption2` support text. **Numbers get `.monospacedDigit()`**
so live counters do not jitter.

**Verify at `.accessibilityXXXL` on a 375pt width.** A concatenated `Text` containing a
formatted number broke *mid-number* there and rendered a different figure — split stacked
values into separate `Text` views rather than joining with a separator.

**A decorative trailing icon beside a status title is removed at `isAccessibilitySize`;** the
label's own symbol carries the state. Kept, the status card's `.title` antenna claimed a
column and broke "Server update needed" mid-word ("Serve / r / up- / date") at
`.accessibilityXXXL` on 375pt, measured 2026-09-13.

## Cards

Rounded rectangle, corner radius 16, `.padding()`, on the card ground. A card that can
render more than one state needs `.frame(maxWidth: .infinity, alignment: .leading)` —
without a width-expanding child, one state collapses to its intrinsic width and the card
visibly changes size between states.

## Before merging a frontend change here

Run the Sasha Kim gate. It renders the real states rather than reading the diff, which is
how every finding above was actually caught.

## Web setup page

The standalone Netlify setup page (`backends/netlify/public/index.html`) uses explicit
light/dark equivalents of the iOS semantic palette: foreground `#1d1d1f/#f5f5f7`,
secondary `#6e6e73/#a1a1a6`, page `#fff/#000`, card `#f5f5f7/#1c1c1e`, and system pink
`#ff2d55/#ff375f`. Pink is reserved for the one visible primary action. Its white-text
contrast exception is the same as the iOS primary action above. Error text uses
`#c4002b` in light mode for readable contrast on the card and `#ff453a` in dark mode.
Buttons have a 44px minimum target. Below 480px, key records stack their label/action,
prefix/status, and last-used date; numbers must not break across narrow table columns.
Errors are live alerts; copy results use a live status. Pending requests disable their
action, and revoking the newly issued key clears its one-time copy panel.

## Website (2026-11-16)

The website shares the pink accent; its dark surfaces use the tokens in
`web/src/layouts/Layout.astro`: `--accent` #ff2d78, `--accent-light` #ff6b9d,
`--surface` #0f1225, `--border` rgba(255,45,120,0.14), `--muted` #9ba5c4,
`--text` #e5e7eb, and `--attention` #fbbf24. Use tokens for new components.

The consent panel sits fixed at the bottom with 16px gutters and a 720px maximum
width. Accept and Decline always have equal weight, neither pink, and minimum
44px touch height. Neutral muted borders distinguish both controls; keyboard
focus uses an accent-light outline. A persistence failure keeps normal body text
inside a 3px attention border with a faint matching tint and 8px by 12px padding.
Number its recovery steps: close the tab, then clear this site's browser data.
Review normal and failure states at 375px plus the normal 1440px layout.
Further website patterns live in `web/design.md`.
