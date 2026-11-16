# Sleep dates in MCP

Verified 2026-11-16. `get_sleep` and `get_coaching_brief` group sleep from local
noon to the next noon, using `HEALTH4AI_TZ`. The date names the evening the night
began. A night dated today is excluded until the next local date; this avoids
presenting an afternoon nap as tonight's completed sleep. Morning naps can still
belong to the preceding night. This is a calendar grouping, not sleep-session
detection, and sleep across noon can span two dates.

The coaching brief includes only nights that ended in its rolling seven-day
window. Its activity figures instead cover seven complete local calendar days,
through yesterday, averaging days with observed data. Missing days are not zeros.

The legacy SQL view `v_healthkit_sleep_nightly`, created by migration 004, retains
its six-hour boundary and fixed America/New_York zone. It is not used by these
MCP tools; migration 009 revokes its anon/authenticated access. Administrators
querying it directly should expect different dates and totals. This change does
not modify that view or deploy a database migration.
