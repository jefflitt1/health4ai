// Imports a CPAP SD card from the command line, with the same reader and upload as the CPAP import
// page (public/cpap.js). Prints counts only, never readings.
//
//   H4A_SETUP_SECRET=<setup secret> node scripts/cpap-import.mjs <card folder> <site URL> \
//     [--tz <IANA zone>] [--dry-run]
//
// Samples are stored for the Owner. The zone defaults to this computer's. The secret is read from
// the environment so it stays out of the shell history and the process list.

import { readFileSync, readdirSync } from 'node:fs'
import { basename, dirname, join } from 'node:path'
import { parseArgs } from 'node:util'
import { pickCardFiles, readCard, readLeakFile, uploadSamples } from '../public/cpap.js'

const { values: opts, positionals } = parseArgs({
  allowPositionals: true,
  options: { tz: { type: 'string' }, 'dry-run': { type: 'boolean' } },
})
const [card, site] = positionals
const secret = process.env.H4A_SETUP_SECRET
if (!card || (!site && !opts['dry-run'])) {
  console.error('Usage: H4A_SETUP_SECRET=<secret> node scripts/cpap-import.mjs <card folder> <site URL> [--tz <zone>] [--dry-run]')
  process.exit(2)
}
// The setup secret and the Samples go in the request, so only over HTTPS, except to this machine
// (netlify dev). Checked before the card is read.
/** @type {URL | undefined} */
let base
if (site) {
  try { base = new URL(site) } catch { /* refused below */ }
  const local = base?.protocol === 'http:' && ['localhost', '127.0.0.1', '[::1]'].includes(base.hostname)
  if (!base || (base.protocol !== 'https:' && !local)) {
    console.error(`The site URL must start with https:// (or http:// for localhost): ${site}`)
    process.exit(2)
  }
}
const timeZone = opts.tz ?? Intl.DateTimeFormat().resolvedOptions().timeZone
try {
  new Intl.DateTimeFormat('en', { timeZone })
} catch {
  console.error(`Unknown time zone ${JSON.stringify(timeZone)}. Use one like America/Toronto.`)
  process.exit(2)
}
if (!opts['dry-run'] && !secret) {
  console.error('Set H4A_SETUP_SECRET to the setup secret.')
  process.exit(2)
}

// Paths as the page sees them: relative to the picked folder's parent, '/'-separated.
const root = basename(card)
const paths = readdirSync(card, { recursive: true, encoding: 'utf8' }).map((p) => `${root}/${p.split('\\').join('/')}`)
const picked = pickCardFiles(paths)
if (!picked.str) {
  console.error(`No STR.edf under ${card}. Pass the SD card's top folder.`)
  process.exit(1)
}
const read = (/** @type {string} */ path) => new Uint8Array(readFileSync(join(dirname(card), path)))
// Each trend file is read in turn and kept only as its leak trace, as the page does.
const leaks = picked.leaks.map((path) => readLeakFile(path, read(path)))
const { samples, stats } = readCard({ str: read(picked.str), events: picked.events.map((path) => ({ path, bytes: read(path) })), leaks }, { timeZone })
console.log(`${stats.nights} Nights, ${stats.events} events, ${Math.round(stats.leakMinutes / 6) / 10} hours of leak trace, ${samples.length} Samples (times in ${timeZone}); ` +
  `${stats.stubSessions} short sessions skipped, ${stats.droppedEvents} events outside therapy and ${stats.droppedLeakFiles} leak traces outside therapy or with no records left out, ` +
  `${stats.unreadable.length} files unreadable`)
for (const { path, reason } of stats.unreadable) console.log(`  unreadable: ${path} (${reason})`)
if (opts['dry-run']) process.exit(0)

const headers = { 'X-Setup-Secret': secret, 'Content-Type': 'application/json' }
const { inserted, batches } = await uploadSamples(samples, {
  // A redirect would carry the secret and the Samples to wherever it points, over any scheme: refuse it.
  post: (batch) => fetch(new URL('/api/setup/samples', base), { method: 'POST', headers, body: JSON.stringify({ samples: batch }), redirect: 'error' }),
  wait: (ms) => {
    console.log('Rate limited; waiting a minute')
    return new Promise((r) => setTimeout(r, ms))
  },
  onProgress: (sent, total) => console.log(`  ${sent}/${total}`),
})
console.log(`Stored ${inserted} Samples in ${batches} requests.`)
