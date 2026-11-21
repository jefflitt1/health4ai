// The setup API's sample upload, which the CPAP import page uses, against a local Netlify
// Database, read back with SQL. Expected behaviour: the same request contract and limits as
// /api/ingest (tests/ingest.test.ts), gated by the setup secret instead of a Device key, storing for
// the Owner; Samples upsert on (person, metric_type, source_device, started_at), so sending a card
// twice stores it once.

import { afterAll, beforeAll, beforeEach, expect, test } from 'vitest'
import { NetlifyDB } from '@netlify/database-dev'
import pg from 'pg'
import { handleSetup } from '../src/setup.ts'
import { ensureOwner } from '../src/store.ts'

const D = 86_400_000
const NOW = Date.now()
let db: NetlifyDB
let pool: pg.Pool
let owner: string
let secret: string

beforeAll(async () => {
  db = new NetlifyDB({ logger: () => {} })
  const connectionString = await db.start()
  await db.applyMigrations('./netlify/database/migrations')
  pool = new pg.Pool({ connectionString, max: 1 })
  // The setup secret as the Owner reads it: straight from the table.
  secret = (await pool.query<{ secret: string }>('SELECT secret FROM setup_secret')).rows[0].secret
})

afterAll(async () => {
  await pool?.end()
  await db?.stop()
})

beforeEach(async () => {
  await pool.query('TRUNCATE healthkit_metrics, device_keys, people CASCADE')
  owner = await ensureOwner(pool)
})

const nights = (n: number, value = 4.5) => Array.from({ length: n }, (_, i) => ({
  metric_type: 'cpap.ahi', value: value + i, unit: 'events/h', source_device: 'AirSense 11',
  started_at: new Date(NOW - (i + 1) * D).toISOString(), ended_at: new Date(NOW - (i + 1) * D + 8 * 3_600_000).toISOString(),
  metadata: { night: `night ${i}` },
}))

const request = (body: string, headers: Record<string, string>) =>
  new Request('https://example.test/api/setup/samples', { method: 'POST', headers, body })

async function upload(body: unknown, presented = secret) {
  const res = await handleSetup(request(JSON.stringify(body), { 'X-Setup-Secret': presented, 'Content-Type': 'application/json' }), () => pool)
  return { status: res.status, body: await res.json() }
}

test('stores a batch for the Owner, with the ingest response', async () => {
  const { status, body } = await upload({ samples: nights(3) })
  expect(status).toBe(200)
  expect(body).toEqual({ inserted: 3, replaced: 0, capabilities: ['merged_hours_v1'] })
  const { rows } = await pool.query(
    'SELECT user_id, metric_type, value, unit, source_device FROM healthkit_metrics ORDER BY value')
  expect(rows).toEqual([4.5, 5.5, 6.5].map((value) => ({
    user_id: owner, metric_type: 'cpap.ahi', value, unit: 'events/h', source_device: 'AirSense 11',
  })))
})

test('sending the same nights again overwrites them instead of adding rows', async () => {
  await upload({ samples: nights(3) })
  await upload({ samples: nights(3, 10) })
  const { rows } = await pool.query('SELECT value FROM healthkit_metrics ORDER BY value')
  expect(rows.map((r) => r.value)).toEqual([10, 11, 12])
})

test('a wrong setup secret is refused and stores nothing', async () => {
  expect(await upload({ samples: nights(1) }, 'wrong')).toEqual({ status: 403, body: { error: 'Wrong setup secret' } })
  const { rows } = await pool.query('SELECT count(*)::int AS n FROM healthkit_metrics')
  expect(rows[0].n).toBe(0)
})

test('no setup secret is refused before the database is touched', async () => {
  const res = await handleSetup(request('{}', { 'Content-Type': 'application/json' }), () => { throw new Error('database touched') })
  expect(res.status).toBe(403)
})

test('the ingest limits and checks apply', async () => {
  const tooMany = await upload({ samples: Array.from({ length: 1001 }, (_, i) => ({ ...nights(1)[0], started_at: new Date(Date.UTC(2026, 0, 1) + i * 1000).toISOString() })) })
  expect(tooMany).toEqual({ status: 400, body: { error: 'Batch size exceeds maximum of 1000 samples' } })
  const badValue = await upload({ samples: [{ ...nights(1)[0], value: 'high' }] })
  expect(badValue).toEqual({ status: 400, body: { error: 'value must be a finite number or null' } })
  const { rows } = await pool.query('SELECT count(*)::int AS n FROM healthkit_metrics')
  expect(rows[0].n).toBe(0)
})

test('a declared body over 5 MB is refused before it is read, as on /api/ingest', async () => {
  const res = await handleSetup(request('{}', {
    'X-Setup-Secret': secret, 'Content-Type': 'application/json', 'Content-Length': String(50 * 1024 * 1024),
  }), () => pool)
  expect(res.status).toBe(413)
})

test('GET is not an upload', async () => {
  const res = await handleSetup(new Request('https://example.test/api/setup/samples', { headers: { 'X-Setup-Secret': secret } }), () => pool)
  expect(res.status).toBe(404)
})

async function clocks(presented = secret) {
  const res = await handleSetup(new Request('https://example.test/api/setup/cpap-clock', { headers: { 'X-Setup-Secret': presented } }), () => pool)
  return { status: res.status, body: await res.json() }
}

test('the Machine clocks earlier imports used, so the page can warn before storing a Night twice', async () => {
  expect(await clocks()).toEqual({ status: 200, body: { clocks: [], unrecorded: false } })
  const clocked = (clock: string | null, from: number) => nights(2).map((s, i) => ({
    ...s, metric_type: 'cpap.usage_hours', unit: 'h', started_at: new Date(NOW - (from + i + 1) * D).toISOString(),
    metadata: clock ? { ...s.metadata, clock } : s.metadata,
  }))
  await upload({ samples: [...clocked('-05:00', 0), ...clocked('America/Toronto', 2), ...clocked(null, 4)] })
  // Only nightly usage Samples are looked at; an event with another clock does not count.
  await upload({ samples: [{ ...nights(1)[0], metric_type: 'cpap.event.hypopnea', metadata: { night: 'x', clock: '+01:00' } }] })
  // Nor does another person's data.
  const other = (await pool.query<{ id: string }>("INSERT INTO people (display_name) VALUES ('Other') RETURNING id")).rows[0].id
  await pool.query(`INSERT INTO healthkit_metrics (user_id, metric_type, value, unit, source_device, started_at, metadata)
    VALUES ($1, 'cpap.usage_hours', 7, 'h', 'AirSense 11', now(), '{"night": "y", "clock": "+09:00"}')`, [other])
  // Nights imported before clocks were recorded count as an unknown clock.
  expect(await clocks()).toEqual({ status: 200, body: { clocks: ['-05:00', 'America/Toronto'], unrecorded: true } })
})

test('the Machine clocks are behind the setup secret', async () => {
  expect((await clocks('wrong')).status).toBe(403)
})
