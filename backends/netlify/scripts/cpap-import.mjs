// @ts-check
// Imports a CPAP SD card from the command line, with the same reader and upload as the CPAP import
// page (public/cpap.js). Prints counts only, never readings.
//
//   H4A_SETUP_SECRET=<setup secret> node scripts/cpap-import.mjs <card folder> <site URL> \
//     [--tz <±HH:MM or IANA zone>] [--dry-run]
//
// Samples are stored for the Owner. The machine's clock is read from the card's settings when it
// records its offset from UTC, otherwise this computer's time zone is used; --tz overrides both
// (write an offset as --tz=-05:00: a value starting with - needs the =). The secret is read from
// the environment so it stays out of the shell history and the process list.

import { readFileSync, readdirSync } from 'node:fs'
import { basename, dirname, join } from 'node:path'
import { parseArgs } from 'node:util'
import { pickCardFiles, readCard, readCardClock, readLeakFile, uploadSamples, wallToInstant } from '../public/cpap.js'

const { values: opts, positionals } = parseArgs({
  allowPositionals: true,
  options: { tz: { type: 'string' }, 'dry-run': { type: 'boolean' } },
})
const [card, site] = positionals
const secret = process.env.H4A_SETUP_SECRET
if (!card || (!site && !opts['dry-run'])) {
  console.error('Usage: H4A_SETUP_SECRET=<secret> node scripts/cpap-import.mjs <card folder> <site URL> [--tz <±HH:MM or zone>] [--dry-run]')
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
if (opts.tz !== undefined) {
  try {
    wallToInstant(0, opts.tz)
  } catch {
    console.error(`Unknown time zone or offset ${JSON.stringify(opts.tz)}. Use one like America/Toronto, or an offset as --tz=-05:00.`)
    process.exit(2)
  }
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
// --tz wins without the settings file being read, so a card whose TimeZoneOffset is unreadable can
// still be imported on a clock given by hand.
/** @type {string | null} */
let cardClock = null
if (!opts.tz && picked.settings) {
  try {
    cardClock = readCardClock(read(picked.settings))
  } catch (e) {
    console.error(`${/** @type {Error} */ (e).message}. Give the machine's clock with --tz, such as --tz=-05:00.`)
    process.exit(2)
  }
}
const timeZone = opts.tz ?? cardClock ?? Intl.DateTimeFormat().resolvedOptions().timeZone
const clockSource = opts.tz ? '--tz' : cardClock ? 'from the card' : "this computer's zone; the card records no offset"
// Each trend file is read in turn and kept only as its leak trace, as the page does.
const leaks = picked.leaks.map((path) => readLeakFile(path, read(path)))
const { samples, stats } = readCard({ str: read(picked.str), events: picked.events.map((path) => ({ path, bytes: read(path) })), leaks }, { timeZone })
console.log(`${stats.nights} Nights, ${stats.events} events, ${Math.round(stats.leakMinutes / 6) / 10} hours of leak trace, ${samples.length} Samples (machine clock ${timeZone}, ${clockSource}); ` +
  `${stats.stubSessions} short sessions skipped, ${stats.droppedEvents} events outside therapy and ${stats.droppedLeakFiles} leak traces outside therapy or with no records left out, ` +
  `${stats.unreadable.length} files unreadable`)
for (const { path, reason } of stats.unreadable) console.log(`  unreadable: ${path} (${reason})`)
for (const reason of stats.skippedSummaries) console.log(`  ${reason}`)
if (opts['dry-run']) process.exit(0)

// Checked above: an upload (not --dry-run) has a secret.
const headers = { 'X-Setup-Secret': /** @type {string} */ (secret), 'Content-Type': 'application/json' }
// Nights already stored on another clock would be stored again at other times: say so, then go on,
// as the page does (the earlier clock may be the wrong one, with its Nights about to be removed). A
// failed check (a site without the route, or a redirect, never followed) only loses the warning.
const clockRes = await fetch(new URL('/api/setup/cpap-clock', base), { headers, redirect: 'error' }).catch(() => null)
const clockBody = clockRes?.ok ? await clockRes.json().catch(() => ({})) : {}
if (!clockRes?.ok) console.warn(`Could not check the clocks of earlier imports (${clockRes ? clockRes.status : 'no response'}); uploading anyway.`)
const otherClocks = /** @type {string[]} */ (clockBody.clocks ?? []).filter((c) => c !== timeZone)
if (otherClocks.length || clockBody.unrecorded) {
  const earlier = [...otherClocks, ...(clockBody.unrecorded ? ['an unrecorded clock (imports made before clocks were recorded)'] : [])]
  console.warn(`Warning: earlier imports used ${earlier.join(', ')}; this one uses ${timeZone}. ` +
    'Nights stored on another clock are stored again at other times unless they are removed.')
}
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
