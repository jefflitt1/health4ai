# Candidate workout details and routes privacy map

Prepared 2026-11-16; not part of submitted build 84. New build, public policy and
App Store privacy declaration review are required before releasing this feature.

Quantity detail exports are manual, default off, and limited to the previously
chosen Health scope. No new quantity permission is requested. HealthKit's exact
workout association supplies UUID, type, original units/value, source display name
and start/end timestamps. These are Health/Fitness data linked to the configured
account for app functionality, not tracking.

GPS routes have separate default-off consent. Only turning on that switch checks
server support and requests read-only workout-route authorization. It does not
start export. Each selected-run export reads exact associated routes, then their
location batches through HKWorkoutRouteQuery. Precise latitude/longitude,
timestamp, altitude (null for invalid vertical fixes), and horizontal/vertical
accuracy are sent to the user's Supabase endpoint. Coordinates may reveal home,
work and movements. The candidate manifest adds Precise Location, linked, app
functionality, no tracking. No CLLocationManager location permission or live
location tracking is used.

The Supabase project owner controls storage/access; health4ai does not receive a
copy. An AI provider connected via the owner's MCP is a separate disclosure choice.
The backend and MCP each require explicit optional feature flags. Each manual
export starts a new revision; up to 16 revisions per workout include incomplete
attempts. No automatic expiry or compaction is promised. Individual and all-account
delete operations are separately available for quantity details and routes, even
with export disabled. Confirmation identifies the category; both deletions are
needed to erase both categories. They do not erase original Health records or
ordinary synced metrics. Turning consent off leaves previously sent data intact.

Local erase removes hkb consent preferences and credentials; it does not remotely
erase database rows or the owner's backups. Database deletion does not promise
removal from external exports, AI conversation history or provider backups.

Only bounded observed data is claimed. A successful permission request does not
prove read access; empty data does not prove absence. Independent quantity queries
and route queries are not an atomic snapshot. Invalid route points retain explicit
counts; original point indexes preserve gaps. Raw step samples are not summed into
merged multi-source totals. No coordinates, health values or credentials enter logs.

Apple references:
- https://developer.apple.com/documentation/healthkit/reading-route-data
- https://developer.apple.com/documentation/healthkit/hkseriessample/count
- https://developer.apple.com/app-store/app-privacy-details/
