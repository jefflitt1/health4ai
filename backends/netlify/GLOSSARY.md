# health4ai

Moves people's Apple Health data into storage they own, so an AI client can query it.

## People and places

**Person**:
Anyone whose health data a Deployment holds.
_Avoid_: User, tenant, account, customer

**Owner**:
The Person who created and runs a Deployment.
_Avoid_: Admin, operator

**Deployment**:
One copy of the Netlify template running on the Owner's Netlify account.
_Avoid_: Instance, hosted tier, server

**Destination**:
Where the iOS app sends data: a Supabase project, a Google Sheet, or a Deployment.
_Avoid_: Backend, connection type, sink

## Access

**Device key**:
A revocable secret a Deployment issues to one device so it can send or read one Person's data.
_Avoid_: API key, token, password

**Setup secret**:
The secret a Deployment generates on its first deploy and keeps in its database; the Owner reads it with their Netlify login and needs it to issue or revoke Device keys.
_Avoid_: Admin password, master key

## Health data

**Sample**:
One reading of one metric, from one source device, starting at one instant.
_Avoid_: Record, row, data point

**Merged hour**:
One UTC hour's total of an activity metric across every device, which replaces that hour's per-device Samples so the same steps are not counted twice.
_Avoid_: Aggregate, rollup

**Daily summary**:
One day's rollup of one metric, with day boundaries in the Person's time zone.
_Avoid_: Daily aggregate
