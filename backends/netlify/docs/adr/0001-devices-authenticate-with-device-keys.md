# Devices authenticate with Device keys; the people gate is pluggable

Every device that talks to a Deployment (the iPhone app, a laptop uploader, an MCP client) sends a revocable Device key, never a person's login. People authenticate only to issue and revoke those keys: with the Setup secret today, and with Netlify Identity once it is enabled, both able to be active at once. We chose this over signing the app in to Netlify Identity because Identity cannot be enabled from a Deploy button, the token endpoint a native app would call is not documented for third-party clients, and a one-person Deployment would use none of Identity's signup, roles or social login. Keeping devices on keys means turning Identity on later changes no app code and invalidates no stored data.

## Consequences

- Health data keys on our own `people.id`, not an auth provider's user ID; Identity adds a link column, not a migration.
- There is no password reset: the Setup secret lives in the Deployment's database, where the Owner reads it with their Netlify login, and deleting its row makes the site generate a new one.
