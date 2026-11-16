# health4ai on Netlify

A backend for the health4ai iOS app that runs on your own Netlify account: the app syncs Apple
Health into a Netlify Database, and the health4ai MCP server queries it. Nothing leaves your
account. Vocabulary: [GLOSSARY.md](GLOSSARY.md).

## What it deploys

- `POST /api/ingest`: the app's sync endpoint, authenticated by a Device key. Same request and
  response contract as the Supabase `healthkit-ingest` function, except that a merged hour of 0 or
  less is skipped, not stored, and counted in a `skipped_merged_hours` response field.
- `/` and `/api/setup/*`: a setup page, behind a setup secret the first deploy generates, that
  issues and revokes Device keys and shows your person ID.
- `netlify/database/migrations/`: the schema, applied by Netlify on every deploy.

## Set up

1. Deploy, with the button or by hand. The first deploy creates the database, applies the
   migrations, and generates your setup secret.
   - **Deploy button**: [![Deploy to Netlify](https://www.netlify.com/img/deploy/button.svg)](https://app.netlify.com/start/deploy?repository=https://github.com/jefflitt1/health4ai&base=backends/netlify)
     Netlify copies the repository to your GitHub account and deploys `backends/netlify`.
   - **By hand**, from a fork. The button's copy is a plain repository, so use a fork if you want
     to pull later changes from this one. Fork it on GitHub, then either:
     - In the Netlify UI, add a new project from your fork and set **Base directory** to
       `backends/netlify`. Leave the other build settings empty: `backends/netlify/netlify.toml`
       sets them.
     - Or, with the [Netlify CLI](https://docs.netlify.com/cli/get-started/), run `netlify init`
       in `backends/netlify` of a clone of your fork and keep `backends/netlify` as the base
       directory when it asks.
2. Read your setup secret. The site never shows it; it is in the `setup_secret` table of your
   site's database, which only your Netlify login can read. Either:
   - In the Netlify UI: your site → **Data & Storage** → **Database**, table `setup_secret`.
   - From a terminal, in `backends/netlify` of a clone of your repository. Needs the
     [Netlify CLI](https://docs.netlify.com/cli/get-started/) and pnpm:
     ```bash
     npm install -g netlify-cli
     netlify login
     netlify link              # pick this site
     pnpm install
     pnpm run setup-secret
     ```
3. Open the site, unlock it with the secret, and issue a Device key for your phone. Paste the site
   URL and key into the app (Connection → Your Netlify site).
4. For the MCP server, copy the person ID into `HEALTHKIT_USER_ID`, and the connection string from
   Data & Storage → Database into `DATABASE_URL`.

To replace the secret, delete its row in `setup_secret`, then try to unlock the setup page once
with any text: the site stores a new secret, which you read the same way. You can also edit the
row to a secret of your own, of 32 characters or more.

## Develop

Tools are pinned in `mise.toml`.

```bash
pnpm install --frozen-lockfile
pnpm test        # unit tests + migrations and SQL against a local Netlify Database
pnpm typecheck
```
