// Device key scopes against a local Netlify Database. Expected behaviour: a key either writes (a
// phone, accepted by /api/ingest) or reads (for a reader such as a dashboard); every key issued
// before scopes existed, and every key issued without one, writes; a lookup for one scope never
// accepts a key of the other; the setup API issues and lists either scope and refuses any other.

import { afterAll, beforeAll, beforeEach, expect, test } from 'vitest'
import { NetlifyDB } from '@netlify/database-dev'
import pg from 'pg'
import { handleIngest } from '../src/ingest.ts'
import { createHash } from 'node:crypto'
import { handleSetup } from '../src/setup.ts'
import { ensureOwner, issueDeviceKey, personForDeviceKey, replaceMergedHours, revokeDeviceKey, upsertDeviceRows } from '../src/store.ts'

let db: NetlifyDB
let pool: pg.Pool
let owner: string
let secret: string

beforeAll(async () => {
  db = new NetlifyDB({ logger: () => {} })
  const connectionString = await db.start()
  await db.applyMigrations('./netlify/database/migrations')
  pool = new pg.Pool({ connectionString, max: 1 })
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

test('a key row written without a scope writes, and no scope but write or read is stored', async () => {
  // As every key issued before this column existed.
  await pool.query(`INSERT INTO device_keys (person_id, key_hash, key_prefix, label) VALUES ($1, 'h1', 'h4a_one', 'old')`, [owner])
  expect((await pool.query('SELECT scope FROM device_keys')).rows).toEqual([{ scope: 'write' }])
  await expect(pool.query(`INSERT INTO device_keys (person_id, key_hash, key_prefix, label, scope) VALUES ($1, 'h2', 'h4a_two', 'x', 'admin')`, [owner]))
    .rejects.toThrow(/device_keys_scope_valid/)
})

test('a read key is not stored under the hash a write lookup computes, so code from before scopes cannot accept it', async () => {
  // A deploy rolled back to before scopes looks keys up by key_hash = sha256(key) alone, keeping
  // the rows this code wrote. A write key must still match that; a read key must not.
  const phone = await issueDeviceKey(pool, owner, 'Phone')
  const reader = await issueDeviceKey(pool, owner, 'Dashboard', 'read')
  const legacy = async (key: string) => (await pool.query(
    'SELECT person_id FROM device_keys WHERE key_hash = $1 AND revoked_at IS NULL', [createHash('sha256').update(key).digest('hex')])).rows.length
  expect([await legacy(phone.key), await legacy(reader.key)]).toEqual([1, 0])
})

test('a lookup for one scope never accepts a key of the other', async () => {
  const phone = await issueDeviceKey(pool, owner, 'Phone')
  const reader = await issueDeviceKey(pool, owner, 'Dashboard', 'read')
  expect([phone.scope, reader.scope]).toEqual(['write', 'read'])
  expect(await personForDeviceKey(pool, phone.key, 'write')).toBe(owner)
  expect(await personForDeviceKey(pool, phone.key, 'read')).toBeNull()
  expect(await personForDeviceKey(pool, reader.key, 'read')).toBe(owner)
  expect(await personForDeviceKey(pool, reader.key, 'write')).toBeNull()
})

const sample = { metric_type: 'HKQuantityTypeIdentifierHeartRate', value: 60, unit: 'count/min', source_device: 'Watch',
  started_at: '2026-10-01T08:00:00Z', ended_at: null, metadata: null }
const ingest = (key: string) => handleIngest(new Request('https://example.test/api/ingest', {
  method: 'POST', headers: { Authorization: `Bearer ${key}`, 'Content-Type': 'application/json' }, body: JSON.stringify({ samples: [sample] }),
}), {
  // As netlify/functions/ingest.mts wires it.
  authenticate: (k) => personForDeviceKey(pool, k, 'write'),
  upsertDeviceRows: (rows) => upsertDeviceRows(pool, rows),
  replaceMergedHours: (userId, rows) => replaceMergedHours(pool, userId, rows),
})

test('/api/ingest refuses a read key, active or revoked, as it does an unknown one, and stores nothing', async () => {
  const reader = await issueDeviceKey(pool, owner, 'Dashboard', 'read')
  const active = await ingest(reader.key)
  expect([active.status, await active.json()]).toEqual([401, { error: 'Unauthorized' }])
  await revokeDeviceKey(pool, owner, reader.id)
  expect((await ingest(reader.key)).status).toBe(401)
  expect((await pool.query('SELECT count(*)::int AS n FROM healthkit_metrics')).rows[0].n).toBe(0)

  const phone = await issueDeviceKey(pool, owner, 'Phone')
  expect((await ingest(phone.key)).status).toBe(200)
})

const setup = async (path: string, init: RequestInit = {}) => {
  const res = await handleSetup(new Request(`https://example.test${path}`, {
    ...init, headers: { 'X-Setup-Secret': secret, 'Content-Type': 'application/json' },
  }), () => pool)
  return { status: res.status, body: await res.json() }
}

test('the setup API issues a write key by default or a read key when asked, and lists the scope', async () => {
  const phone = await setup('/api/setup/keys', { method: 'POST', body: JSON.stringify({ label: 'Phone' }) })
  const reader = await setup('/api/setup/keys', { method: 'POST', body: JSON.stringify({ label: 'Dashboard', scope: 'read' }) })
  expect([phone.status, phone.body.scope, reader.status, reader.body.scope]).toEqual([201, 'write', 201, 'read'])
  const { body } = await setup('/api/setup/keys')
  expect(body.keys.map((k: { label: string; scope: string }) => [k.label, k.scope]).sort()).toEqual([['Dashboard', 'read'], ['Phone', 'write']])
})

test.each([['admin'], [''], [1], [null]])('the setup API refuses scope %j and issues nothing', async (scope) => {
  const res = await setup('/api/setup/keys', { method: 'POST', body: JSON.stringify({ label: 'x', scope }) })
  expect(res).toEqual({ status: 400, body: { error: 'scope must be "write" or "read"' } })
  expect((await pool.query('SELECT count(*)::int AS n FROM device_keys')).rows[0].n).toBe(0)
})

test.each([['"hello"'], ['5'], ['true']])('a JSON body that is not an object (%s) still issues a write key, as before scopes', async (body) => {
  const res = await setup('/api/setup/keys', { method: 'POST', body })
  expect([res.status, res.body.scope, res.body.label]).toEqual([201, 'write', ''])
})
