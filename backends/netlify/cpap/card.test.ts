// The CPAP card reader on a real SD card, checked against invariants rather than values: the card
// is someone's health data, so nothing here asserts or prints a reading. Every check counts the
// Samples that break it and expects zero, so a failure prints a count, never a value; only
// aggregate counts are logged.
//
// Opt-in, because it needs a card: `CPAP_CARD=/path/to/card pnpm test:cpap`, the folder holding
// STR.edf and DATALOG/.

import { expect, test } from 'vitest'
import { readFileSync, readdirSync } from 'node:fs'
import { basename, dirname, join } from 'node:path'
import { BATCH_SIZE, parseEdf, pickCardFiles, readCard, readCardClock, readLeakFile, type Sample } from '../public/cpap.js'

const CARD = process.env.CPAP_CARD
const COMPUTER_ZONE = Intl.DateTimeFormat().resolvedOptions().timeZone
const MINUTE = 60_000

/** Reads the picked files, and only those, recording every path read. */
function readPicked() {
  const root = basename(CARD!)
  const relative = (readdirSync(CARD!, { recursive: true }) as string[]).map((p) => `${root}/${p.split('\\').join('/')}`)
  const picked = pickCardFiles(relative)
  const reads: string[] = []
  const read = (path: string) => {
    reads.push(path)
    return new Uint8Array(readFileSync(join(dirname(CARD!), path)))
  }
  // The clock the page would use: the card's own offset, else this computer's zone.
  const clock = (picked.settings ? readCardClock(read(picked.settings)) : null) ?? COMPUTER_ZONE
  const card = {
    str: read(picked.str!),
    events: picked.events.map((path) => ({ path, bytes: read(path) })),
    leaks: picked.leaks.map((path) => readLeakFile(path, read(path))),
  }
  return { relative, picked, reads, card, clock }
}

const count = <T>(items: T[], bad: (item: T) => boolean) => items.filter(bad).length

test.skipIf(!CARD)('a real card reads into sane, repeatable Samples without touching the waveforms', () => {
  const { relative, picked, reads, card, clock } = readPicked()
  const eventFiles = relative.filter((p) => /\/DATALOG\/\d{8}\/[^/]+_(EVE|CSL)\.edf$/.test(p))
  const trendFiles = relative.filter((p) => /\/DATALOG\/\d{8}\/[^/]+_PLD\.edf$/.test(p))
  expect(picked.str).not.toBeNull()
  expect(count(reads, (p) => /_(BRP|SA2)\.edf$/i.test(p))).toBe(0)
  expect(reads.length).toBe(1 + (picked.settings ? 1 : 0) + eventFiles.length + trendFiles.length)

  const { samples, nights, stats } = readCard(card, { timeZone: clock })
  // The reasons name files and signals, never readings.
  if (stats.unreadable.length) console.log('unreadable:', [...new Set(stats.unreadable.map((u) => u.reason))].join('; '))
  expect(stats.unreadable.length).toBe(0)

  // Each EVE and CSL file sits in the folder of its Night by the noon rule.
  const folderOf = (path: string) => path.split('/').at(-2)!
  const noonRule = (wall: number) => new Date(wall - 12 * 60 * MINUTE).toISOString().slice(0, 10).replaceAll('-', '')
  expect(count(card.events, (f) => noonRule(parseEdf(f.bytes).startWall) !== folderOf(f.path))).toBe(0)

  // Every Night inside the DATALOG span has a folder; a folder that is no Night held only stubs.
  const folders = new Set(card.events.filter((f) => f.path.endsWith('_EVE.edf')).map((f) => folderOf(f.path)))
  const nightFolders = new Set(nights.map((n) => n.date.replaceAll('-', '')))
  const [first, last] = [[...folders].sort()[0], [...folders].sort().at(-1)!]
  expect(count([...nightFolders], (d) => d >= first && d <= last && !folders.has(d))).toBe(0)
  expect(count([...folders], (d) => !nightFolders.has(d))).toBeLessThanOrEqual(stats.stubSessions)

  const leakTraces = samples.filter((s) => s.metric_type === 'cpap.leak_trace')
  const nightly = samples.filter((s) => !s.metric_type.startsWith('cpap.event.') && s.metric_type !== 'cpap.leak_trace')
  const events = samples.filter((s) => s.metric_type.startsWith('cpap.event.'))
  const night = (s: Sample) => (s.metadata as { night: string }).night
  const of = (type: string) => nightly.filter((s) => s.metric_type === type)
  expect(nightly.length).toBe(4 * nights.length)
  for (const type of ['cpap.ahi', 'cpap.usage_hours', 'cpap.leak_p95', 'cpap.pressure_median']) {
    expect(new Set(of(type).map(night)).size).toBe(nights.length)
  }
  expect(count(of('cpap.ahi'), (s) => !(s.value! >= 0 && s.value! <= 100))).toBe(0)
  expect(count(of('cpap.usage_hours'), (s) => !(s.value! > 0 && s.value! <= 24))).toBe(0)
  expect(count(of('cpap.leak_p95'), (s) => !(s.value! >= 0))).toBe(0)
  expect(count(of('cpap.pressure_median'), (s) => !(s.value! >= 0 && s.value! <= 40))).toBe(0)

  // Every event starts and ends inside its Night, give or take STR.edf's minute resolution.
  const span = new Map(of('cpap.usage_hours').map((s) => [night(s), [Date.parse(s.started_at) - MINUTE, Date.parse(s.ended_at!) + MINUTE]]))
  expect(events.length).toBe(stats.events)
  expect(count(events, (s) => {
    const [from, to] = span.get(night(s)) ?? [NaN, NaN]
    const start = Date.parse(s.started_at), end = Date.parse(s.ended_at!)
    return !(start >= from && end <= to && end >= start && s.value !== null && s.value >= 0)
  })).toBe(0)

  // Every leak trace lies inside its Night, holds at most an hour of minutes, and its minute values
  // are L/min or unknown; together they hold every minute the card's traces had.
  expect(leakTraces.length).toBeGreaterThan(0)
  expect(count(leakTraces, (s) => {
    const [from, to] = span.get(night(s)) ?? [NaN, NaN]
    const { minute0, lpm } = s.metadata as { minute0: string; lpm: (number | null)[] }
    const start = Date.parse(s.started_at), end = Date.parse(s.ended_at!)
    return !(start >= from && end <= to && end > start && Date.parse(minute0) % MINUTE === 0 && Date.parse(minute0) <= start &&
      lpm.length >= 1 && lpm.length <= 60 && lpm.every((v) => v === null || (Number.isFinite(v) && v >= 0)))
  })).toBe(0)
  expect(leakTraces.reduce((n, s) => n + (s.metadata as { lpm: (number | null)[] }).lpm.filter((v) => v !== null).length, 0)).toBe(stats.leakMinutes)

  // Every Sample passes the ingest checks, and no two share an upsert key.
  expect(count(samples, (s) => s.source_device !== 'AirSense 11' || !/^cpap\.[a-z0-9_.]+$/.test(s.metric_type) ||
    !/^\d{4}-\d{2}-\d{2}$/.test(night(s)) || JSON.stringify(s.metadata).length > 4096 || s.metric_type.length > 256 ||
    (s.value !== null && !Number.isFinite(s.value)))).toBe(0)
  expect(samples.length - new Set(samples.map((s) => `${s.metric_type} ${Date.parse(s.started_at)}`)).size).toBe(0)

  // A second read of the same card gives the same Samples, compared without printing them.
  expect(JSON.stringify(readCard(readPicked().card, { timeZone: clock }).samples) === JSON.stringify(samples)).toBe(true)
  expect(count(samples, (s) => (s.metadata as { clock?: string }).clock !== clock)).toBe(0)

  // The upload fits the setup API: under its 30 requests a minute, each batch under 5 MB.
  const batches = Math.ceil(samples.length / BATCH_SIZE)
  expect(batches).toBeLessThan(30)
  for (let i = 0; i < samples.length; i += BATCH_SIZE) {
    expect(JSON.stringify({ samples: samples.slice(i, i + BATCH_SIZE) }).length).toBeLessThan(5 * 1024 * 1024)
  }

  const types = new Set(events.map((s) => s.metric_type)).size
  console.log(`card: ${stats.nights} nights (${folders.size} DATALOG folders), ${stats.sessions} sessions, ` +
    `${stats.stubSessions} stub sessions skipped, ${stats.events} events of ${types} types, ` +
    `${stats.droppedEvents} events dropped, ${Math.round(stats.leakMinutes / 60)} hours of leak trace in ${leakTraces.length} Samples, ` +
    `${reads.length} files read, ${batches} upload batches`)
})

// Reading a card on a fixed clock instead of a zone with daylight time moves each Sample by the
// zone's daylight hour or not at all, and changes nothing else: the same Nights, values and counts.
// Opt-in like the test above; skipped for a card that records no clock.
test.skipIf(!CARD)('the card\'s fixed clock and a daylight-time zone differ only by whole hours', () => {
  const { card, clock } = readPicked()
  if (!/^[+-]\d\d:\d\d$/.test(clock)) return
  const fixed = readCard(card, { timeZone: clock })
  const zoned = readCard(card, { timeZone: 'America/Toronto' })
  expect(zoned.stats).toEqual(fixed.stats)
  expect(zoned.nights).toEqual(fixed.nights)
  // Paired by type, Night and order within them; the clock is the only metadata that may differ.
  const key = (s: Sample) => `${s.metric_type} ${(s.metadata as { night: string }).night}`
  const groups = (samples: Sample[]) => {
    const out = new Map<string, Sample[]>()
    for (const s of samples) out.set(key(s), [...(out.get(key(s)) ?? []), s])
    return out
  }
  const [a, b] = [groups(fixed.samples), groups(zoned.samples)]
  expect([...b.keys()].sort()).toEqual([...a.keys()].sort())
  const shifts = new Map<number, number>()
  let other = 0
  for (const [k, fs] of a) {
    fs.forEach((f, i) => {
      const z = b.get(k)![i]
      const shift = Date.parse(f.started_at) - Date.parse(z.started_at)
      shifts.set(shift, (shifts.get(shift) ?? 0) + 1)
      const strip = (s: Sample) => ({ ...s, started_at: '', ended_at: '', metadata: { ...(s.metadata as object), clock: '', minute0: '' } })
      if (JSON.stringify(strip(f)) !== JSON.stringify(strip(z))) other++
    })
  }
  expect(other).toBe(0)
  expect([...shifts.keys()].filter((ms) => ms !== 0 && Math.abs(ms) !== 3_600_000)).toEqual([])
  console.log(`clock ${clock} vs America/Toronto: ${[...shifts].map(([ms, n]) => `${n} Samples moved ${ms / 1000} s`).join(', ')}`)
})
