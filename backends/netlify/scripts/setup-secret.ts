// Prints this site's setup secret: `pnpm run setup-secret` (README "Set up", step 2).
//
// Needs the Netlify CLI, logged in, with this directory linked to the site (`netlify link`). The
// CLI hands over the production database's connection string; it stays in this process and is
// never printed. Those credentials can read but not write the table, so a deleted secret is
// replaced by the site itself (on its next setup request), not here.

import { execFileSync } from 'node:child_process'
import pg from 'pg'

function fail(message: string): never {
  console.error(message)
  process.exit(1)
}

let status: { database?: { connectionString?: string } }
try {
  status = JSON.parse(execFileSync(
    'netlify',
    ['database', 'status', '--branch', 'production', '--show-credentials', '--json'],
    { encoding: 'utf8', stdio: ['ignore', 'pipe', 'inherit'] },
  ))
} catch (err) {
  fail(`The Netlify CLI could not report this site's database (${(err as Error).message}).\n`
    + 'Install it (npm install -g netlify-cli), run `netlify login`, then `netlify link` in backends/netlify.')
}

const connectionString = status.database?.connectionString
if (!connectionString) {
  fail('The Netlify CLI returned no production database for this site. Has it deployed once?')
}

// pg already treats sslmode=require as verify-full; saying so explicitly keeps that behaviour
// and silences its warning about the next major version.
const client = new pg.Client({ connectionString: connectionString.replace('sslmode=require', 'sslmode=verify-full') })
try {
  await client.connect()
  const { rows } = await client.query<{ secret: string }>('SELECT secret FROM setup_secret')
  if (!rows[0]) {
    fail('No setup secret is stored. Open the site, try to unlock it once with any text so it stores a new one, then run this again.')
  }
  console.log(rows[0].secret)
} catch (err) {
  fail(`Could not read the setup secret: ${(err as Error).message}`)
} finally {
  await client.end()
}
