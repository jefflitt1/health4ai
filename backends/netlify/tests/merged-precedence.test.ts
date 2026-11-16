import { afterAll, beforeAll, beforeEach, expect, test } from 'vitest'
import { NetlifyDB } from '@netlify/database-dev'
import { randomUUID } from 'node:crypto'
import { readdir, readFile } from 'node:fs/promises'
import pg from 'pg'
import { ensureOwner, replaceMergedHours, upsertDeviceRows } from '../src/store.ts'

let embedded: NetlifyDB | undefined
let admin: pg.Pool | undefined
let pool: pg.Pool
const database = `h4a_precedence_${randomUUID().replaceAll('-', '')}`
const realPostgres = process.env.H4A_TEST_POSTGRES_URL
const metric = 'HKQuantityTypeIdentifierStepCount'
const start = '2026-10-01T08:00:00Z', end = '2026-10-01T09:00:00Z'
const merged = [{ metric_type: metric, value: 1200, unit: 'count', metadata: null,
  started_at: start, ended_at: end }]
const device = (user: string, overrides = {}) => ({ user_id: user, metric_type: metric,
  value: 100, unit: 'count', source_device: 'Watch', started_at: '2026-10-01T08:10:00Z',
  ended_at: '2026-10-01T08:15:00Z', metadata: null, ...overrides })

beforeAll(async () => {
  if (realPostgres) {
    const url = new URL(realPostgres)
    if (!['localhost', '127.0.0.1', '[::1]'].includes(url.hostname)) throw new Error('test database must be local')
    admin = new pg.Pool({ connectionString: url.href })
    await admin.query(`CREATE DATABASE ${database}`)
    url.pathname = `/${database}`
    pool = new pg.Pool({ connectionString: url.href, max: 4 })
    const folder = './netlify/database/migrations'
    for (const file of (await readdir(folder)).filter(f => f.endsWith('.sql')).sort()) {
      await pool.query(await readFile(`${folder}/${file}`, 'utf8'))
    }
  } else {
    embedded = new NetlifyDB({ logger: () => {} })
    pool = new pg.Pool({ connectionString: await embedded.start(), max: 1 })
    await embedded.applyMigrations('./netlify/database/migrations')
  }
})
afterAll(async () => {
  await pool?.end()
  await embedded?.stop()
  if (admin) { await admin.query(`DROP DATABASE ${database}`); await admin.end() }
})
beforeEach(async () => { await pool.query('TRUNCATE healthkit_metrics, people CASCADE') })

async function stored(user: string) {
  return (await pool.query('SELECT sum(value)::int AS total, count(*)::int AS count FROM healthkit_metrics WHERE user_id=$1', [user])).rows[0]
}

test('late device rows cannot add to a stored merged hour', async () => {
  const user = await ensureOwner(pool)
  await replaceMergedHours(pool, user, merged)
  expect(await upsertDeviceRows(pool, [device(user)])).toBe(0)
  expect(await stored(user)).toEqual({ total: 1200, count: 1 })
})

test('precedence is scoped to the person, metric and half-open hour', async () => {
  const user = await ensureOwner(pool)
  const other = (await pool.query("INSERT INTO people(display_name) VALUES ('Other') RETURNING id")).rows[0].id
  await replaceMergedHours(pool, user, merged)
  expect(await upsertDeviceRows(pool, [device(user), device(other),
    device(user, { started_at: end, ended_at: '2026-10-01T09:10:00Z' }),
    device(user, { metric_type: 'HKQuantityTypeIdentifierHeartRate' })])).toBe(3)
  expect(await stored(user)).toEqual({ total: 1400, count: 3 })
  expect(await stored(other)).toEqual({ total: 100, count: 1 })
})

// PGlite serializes queries; use real local PostgreSQL to exercise lock waits between sessions.
for (const first of ['merged', 'device']) {
  test.skipIf(!realPostgres)(`concurrent ${first}-first transaction retains only merged total`, async () => {
    const user = await ensureOwner(pool)
    const a = await pool.connect(), b = await pool.connect()
    let pending: Promise<unknown> | undefined
    try {
      await a.query('BEGIN')
      if (first === 'merged') await replaceMergedHours(a, user, merged)
      else await upsertDeviceRows(a, [device(user)])
      const pid = (await b.query('SELECT pg_backend_pid() AS pid')).rows[0].pid
      pending = first === 'merged' ? upsertDeviceRows(b, [device(user)]) : replaceMergedHours(b, user, merged)
      let waiting = false
      for (let i = 0; i < 100; i++) {
        const state = (await pool.query('SELECT wait_event_type FROM pg_stat_activity WHERE pid=$1', [pid])).rows[0]
        if (state?.wait_event_type === 'Lock') { waiting = true; break }
        await new Promise(resolve => setTimeout(resolve, 10))
      }
      expect(waiting).toBe(true)
      await a.query('COMMIT')
      await pending
      expect(await stored(user)).toEqual({ total: 1200, count: 1 })
    } finally {
      await a.query('ROLLBACK')
      await pending
      a.release(); b.release()
    }
  })
}
