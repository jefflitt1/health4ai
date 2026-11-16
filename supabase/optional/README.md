# Optional workout detail storage

Not included in `web/public/schema.sql` or automatic customer setup. Do not enable
the edge-function or MCP feature flag until the reviewed deployment packet,
retention disclosure, native opt-in and erase integration are ready.

`workout-details-v1.sql` installs tables and a serialized service-only RPC in a
user-owned Supabase project. `workout-routes-v1.sql` is a separate optional location
schema with its own endpoint/capability/consent. Neither changes existing metric
retention, permissions, sync or the submitted build 84. They are not deployed.

See [wire contract](../../docs/workout-detail-wire-v1.md) and
[deployment packet](../../docs/workout-detail-deployment.md).
