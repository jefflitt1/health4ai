// Expected values come from the contract the Supabase function documents
// (supabase/functions/healthkit-ingest/index.ts and its comments), which the iOS app is built
// against: status codes, error strings, and the {inserted, replaced, capabilities} shape. The
// rule for merged hours of 0 or less, which the Supabase function lacks, comes from src/ingest.ts's
// comments: such an hour is skipped (not written, deletes nothing), the rest of the batch is stored,
// the skip is counted in `skipped_merged_hours` (present only when nonzero), and within a batch it
// never displaces a positive merged row for the same hour.

import { describe, expect, test, vi } from 'vitest'
import { handleIngest, type IngestDeps, type MergedHourRow, type MetricRow } from '../src/ingest.ts'

const USER = '11111111-1111-4111-8111-111111111111'
const KEY = 'h4a_valid'
const STEPS = 'HKQuantityTypeIdentifierStepCount'
const MERGED = 'HealthKit (all sources)'

function fakeDeps() {
  const calls = { device: [] as MetricRow[][], merged: [] as MergedHourRow[][] }
  const deps: IngestDeps = {
    authenticate: async (key) => (key === KEY ? USER : null),
    upsertDeviceRows: async (rows) => { calls.device.push(rows); return rows.length },
    replaceMergedHours: async (_u, rows) => { calls.merged.push(rows); return { written: rows.length, deleted: 3 } },
  }
  return { deps, calls }
}

function post(body: unknown, headers: Record<string, string> = {}) {
  return new Request('https://example.test/api/ingest', {
    method: 'POST',
    headers: { Authorization: `Bearer ${KEY}`, 'Content-Type': 'application/json', ...headers },
    body: typeof body === 'string' ? body : JSON.stringify(body),
  })
}

const sample = (over: Record<string, unknown> = {}) => ({
  metric_type: 'HKQuantityTypeIdentifierHeartRate',
  value: 61,
  unit: 'count/min',
  source_device: 'Apple Watch',
  started_at: '2026-10-01T08:00:00Z',
  ended_at: '2026-10-01T08:00:00Z',
  ...over,
})

const mergedHour = (over: Record<string, unknown> = {}) => sample({
  metric_type: STEPS, value: 1200, unit: 'count', source_device: MERGED,
  started_at: '2026-10-01T08:00:00Z', ended_at: '2026-10-01T09:00:00Z', ...over,
})

async function run(req: Request) {
  const { deps, calls } = fakeDeps()
  const res = await handleIngest(req, deps)
  const text = await res.text()
  let body: any = text
  try { body = JSON.parse(text) } catch { /* plain text */ }
  return { status: res.status, body, calls }
}

describe('request gate', () => {
  test('non-POST is 405', async () => {
    const { status } = await run(new Request('https://example.test/api/ingest'))
    expect(status).toBe(405)
  })

  test('declared Content-Length over 5 MB is 413 before auth', async () => {
    const { status, body } = await run(post({ samples: [] }, { 'content-length': String(5 * 1024 * 1024 + 1), Authorization: '' }))
    expect(status).toBe(413)
    expect(body.error).toBe('Request body exceeds maximum size')
  })

  test('missing Authorization is 401', async () => {
    const { status, body } = await run(post({ samples: [] }, { Authorization: '' }))
    expect(status).toBe(401)
    expect(body.error).toBe('Missing Authorization header')
  })

  test('unknown or revoked Device key is 401', async () => {
    const { status, body } = await run(post({ samples: [] }, { Authorization: 'Bearer h4a_wrong' }))
    expect(status).toBe(401)
    expect(body.error).toBe('Unauthorized')
  })

  test('a body over 5 MB without Content-Length is 413', async () => {
    const big = new TextEncoder().encode('x'.repeat(5 * 1024 * 1024 + 1))
    const stream = new ReadableStream({ start(c) { c.enqueue(big); c.close() } })
    const req = new Request('https://example.test/api/ingest', {
      method: 'POST', headers: { Authorization: `Bearer ${KEY}` }, body: stream, duplex: 'half',
    } as RequestInit)
    const { status } = await run(req)
    expect(status).toBe(413)
  })
})

describe('payload shape', () => {
  test('invalid JSON is 400', async () => {
    expect((await run(post('{not json'))).status).toBe(400)
  })

  test.each([['null'], ['[]'], ['5']])('top-level %s is 400', async (raw) => {
    const { status, body } = await run(post(raw))
    expect(status).toBe(400)
    expect(body.error).toBe('Body must be a JSON object')
  })

  test('empty batch answers with capabilities and writes nothing', async () => {
    const { status, body, calls } = await run(post({ samples: [] }))
    expect(status).toBe(200)
    expect(body).toEqual({ inserted: 0, capabilities: ['merged_hours_v1'] })
    expect(calls.device).toEqual([])
  })

  test('more than 1000 samples is 400', async () => {
    const samples = Array.from({ length: 1001 }, (_, i) => sample({ started_at: new Date(Date.UTC(2026, 0, 1) + i * 1000).toISOString() }))
    const { status, body } = await run(post({ samples }))
    expect(status).toBe(400)
    expect(body.error).toBe('Batch size exceeds maximum of 1000 samples')
  })

  test('a string field over 256 characters is 400', async () => {
    const { status } = await run(post({ samples: [sample({ source_device: 'x'.repeat(257) })] }))
    expect(status).toBe(400)
  })

  test('absent metadata is accepted (the app omits nil optionals)', async () => {
    const s = sample()
    expect('metadata' in s).toBe(false)
    const { status, calls } = await run(post({ samples: [s] }))
    expect(status).toBe(200)
    expect(calls.device[0][0].metadata).toBeNull()
  })

  test('array metadata is 400', async () => {
    const { status, body } = await run(post({ samples: [sample({ metadata: [1] })] }))
    expect(status).toBe(400)
    expect(body.error).toBe('Metadata must be an object or null')
  })

  test('metadata over 4096 bytes is 400', async () => {
    const { status, body } = await run(post({ samples: [sample({ metadata: { blob: 'x'.repeat(4100) } })] }))
    expect(status).toBe(400)
    expect(body.error).toBe('Metadata exceeds maximum size of 4096 bytes')
  })

  test.each([['not a date'], [12345], [null]])('started_at %s is 400', async (v) => {
    const { status, body } = await run(post({ samples: [sample({ started_at: v })] }))
    expect(status).toBe(400)
    expect(body.error).toBe('started_at must be an ISO-8601 timestamp')
  })

  test('malformed ended_at is 400; null ended_at is fine', async () => {
    expect((await run(post({ samples: [sample({ ended_at: 'nope' })] }))).status).toBe(400)
    expect((await run(post({ samples: [sample({ ended_at: null })] }))).status).toBe(200)
  })
})

describe('merged hours', () => {
  const MERGED_ERROR = 'Merged rows must cover exactly one UTC hour of a merged activity type'

  test('a whole UTC hour of steps goes to replaceMergedHours, not the upsert', async () => {
    const { status, body, calls } = await run(post({ samples: [mergedHour()] }))
    expect(status).toBe(200)
    expect(body).toEqual({ inserted: 1, replaced: 3, capabilities: ['merged_hours_v1'] })
    expect(calls.device).toEqual([])
    expect(calls.merged[0]).toEqual([{
      metric_type: STEPS, value: 1200, unit: 'count', metadata: null,
      started_at: '2026-10-01T08:00:00.000Z', ended_at: '2026-10-01T09:00:00.000Z',
    }])
  })

  test('timestamps are passed on canonically, whatever offset the client used', async () => {
    const { calls } = await run(post({ samples: [mergedHour({ started_at: '2026-10-01T04:00:00-04:00', ended_at: '2026-10-01T05:00:00-04:00' })] }))
    expect(calls.merged[0][0].started_at).toBe('2026-10-01T08:00:00.000Z')
  })

  test.each([
    ['instantaneous type', { metric_type: 'HKQuantityTypeIdentifierHeartRate' }],
    ['not on the hour', { started_at: '2026-10-01T08:30:00Z', ended_at: '2026-10-01T09:30:00Z' }],
    ['longer than an hour', { ended_at: '2026-10-01T10:00:00Z' }],
    ['missing ended_at', { ended_at: null }],
    ['microsecond precision', { started_at: '2026-10-01T08:00:00.000001Z' }],
  ])('%s is 400', async (_name, over) => {
    const { status, body } = await run(post({ samples: [mergedHour(over)] }))
    expect(status).toBe(400)
    expect(body.error).toBe(MERGED_ERROR)
  })

  test.each([['"1200"'], ['"NaN"'], ['true']])('value %s is 400', async (raw) => {
    const { status, body } = await run(post({ samples: [mergedHour({ value: JSON.parse(raw) })] }))
    expect(status).toBe(400)
    expect(body.error).toBe('Merged rows must carry a finite numeric value')
  })
})

describe('a merged hour of 0 or less', () => {
  const nineOClock = { started_at: '2026-10-01T09:00:00Z', ended_at: '2026-10-01T10:00:00Z' }
  const mergedAt8 = {
    metric_type: STEPS, value: 1200, unit: 'count', metadata: null,
    started_at: '2026-10-01T08:00:00.000Z', ended_at: '2026-10-01T09:00:00.000Z',
  }

  test('a 0 is skipped: replaceMergedHours is not called and the response counts it', async () => {
    const warn = vi.spyOn(console, 'warn').mockImplementation(() => {})
    try {
      const { status, body, calls } = await run(post({ samples: [mergedHour({ value: 0 })] }))
      expect(status).toBe(200)
      expect(body).toEqual({ inserted: 0, replaced: 0, skipped_merged_hours: 1, capabilities: ['merged_hours_v1'] })
      expect(calls.merged).toEqual([])
      expect(calls.device).toEqual([])
      // The log carries the count, never row contents.
      expect(warn).toHaveBeenCalledTimes(1)
      expect(warn.mock.calls[0][1]).toEqual({ count: 1 })
      expect(JSON.stringify(warn.mock.calls)).not.toContain(STEPS)
    } finally {
      warn.mockRestore()
    }
  })

  test.each([[-1], [-0.5]])('a negative value %s is skipped and counted, and the rest of the batch is stored', async (value) => {
    const { status, body, calls } = await run(post({ samples: [sample(), mergedHour({ value })] }))
    expect(status).toBe(200)
    expect(body).toEqual({ inserted: 1, replaced: 0, skipped_merged_hours: 1, capabilities: ['merged_hours_v1'] })
    expect(calls.device).toEqual([[expect.objectContaining({ metric_type: 'HKQuantityTypeIdentifierHeartRate', value: 61 })]])
    expect(calls.merged).toEqual([])
  })

  test('in a mixed batch, the device rows and the real merged hour are stored and counted as before', async () => {
    const { status, body, calls } = await run(post({ samples: [
      sample(),
      mergedHour(),
      mergedHour({ value: 0, ...nineOClock }),
    ] }))
    expect(status).toBe(200)
    // Fake deps: the upsert writes every row it gets (1), the replace writes each merged row (1)
    // and reports 3 deleted.
    expect(body).toEqual({ inserted: 2, replaced: 3, skipped_merged_hours: 1, capabilities: ['merged_hours_v1'] })
    expect(calls.device).toEqual([[expect.objectContaining({ metric_type: 'HKQuantityTypeIdentifierHeartRate', value: 61 })]])
    expect(calls.merged).toEqual([[mergedAt8]])
  })

  // The hour is stored, so nothing is reported as skipped.
  test.each([
    ['1200 then 0', [1200, 0]],
    ['0 then 1200', [0, 1200]],
    ['1200 then -1', [1200, -1]],
  ])('%s for the same hour in one batch stores the 1200', async (_name, values) => {
    const { status, body, calls } = await run(post({ samples: values.map((value) => mergedHour({ value })) }))
    expect(status).toBe(200)
    expect(body).toEqual({ inserted: 1, replaced: 3, capabilities: ['merged_hours_v1'] })
    expect(calls.merged).toEqual([[mergedAt8]])
  })

  test('a 0 is counted once when the batch repeats it, since the skip follows dedup', async () => {
    const { body } = await run(post({ samples: [
      mergedHour({ value: 0 }),
      mergedHour({ value: 0, started_at: '2026-10-01T08:00:00+00:00', ended_at: '2026-10-01T09:00:00+00:00' }),
    ] }))
    expect(body.skipped_merged_hours).toBe(1)
  })

  test('a per-device 0 is still stored', async () => {
    const { status, body, calls } = await run(post({ samples: [sample({ metric_type: STEPS, value: 0, unit: 'count', source_device: 'iPhone' })] }))
    expect(status).toBe(200)
    expect(calls.device[0][0].value).toBe(0)
    expect(body).not.toHaveProperty('skipped_merged_hours')
  })

  test('a batch without one has no skipped_merged_hours key', async () => {
    const { status, body } = await run(post({ samples: [sample(), mergedHour(), mergedHour(nineOClock)] }))
    expect(status).toBe(200)
    expect(body).not.toHaveProperty('skipped_merged_hours')
    expect(body).toEqual({ inserted: 3, replaced: 3, capabilities: ['merged_hours_v1'] })
  })
})

describe('in-batch dedup', () => {
  test('"+00:00" and "Z" spellings of one instant collapse to one row, last wins', async () => {
    const { calls } = await run(post({ samples: [
      sample({ value: 1, started_at: '2026-10-01T08:00:00+00:00' }),
      sample({ value: 2, started_at: '2026-10-01T08:00:00Z' }),
    ] }))
    expect(calls.device[0]).toHaveLength(1)
    expect(calls.device[0][0].value).toBe(2)
  })

  test('two devices at the same instant are two rows', async () => {
    const { calls } = await run(post({ samples: [sample({ source_device: 'Apple Watch' }), sample({ source_device: 'Oura' })] }))
    expect(calls.device[0]).toHaveLength(2)
  })

  test('a "|" inside a field cannot merge two distinct samples', async () => {
    const { calls } = await run(post({ samples: [
      sample({ metric_type: 'A|B', source_device: 'C' }),
      sample({ metric_type: 'A', source_device: 'B|C' }),
    ] }))
    expect(calls.device[0]).toHaveLength(2)
  })

  test('user_id comes from the Device key, never the body', async () => {
    const { calls } = await run(post({ samples: [sample({ user_id: '22222222-2222-4222-8222-222222222222' })] }))
    expect(calls.device[0][0].user_id).toBe(USER)
  })
})

test('a storage error is a 500 that names no row contents', async () => {
  const { deps } = fakeDeps()
  deps.upsertDeviceRows = async () => { throw Object.assign(new Error('boom'), { code: '22P02' }) }
  const res = await handleIngest(post({ samples: [sample()] }), deps)
  expect(res.status).toBe(500)
  expect(await res.json()).toEqual({ error: 'Unable to store samples' })
})

describe('per-device sample shape', () => {
  test.each([
    ['a null element', null, 'Each sample must be a JSON object'],
    ['a missing metric_type', sample({ metric_type: undefined }), 'metric_type must be a non-empty string'],
    ['a numeric metric_type', sample({ metric_type: 7 }), 'metric_type must be a non-empty string'],
    ['a string value', sample({ value: 'abc' }), 'value must be a finite number or null'],
  ])('%s is 400, not a retried 500', async (_name, s, error) => {
    const { status, body } = await run(post({ samples: [s] }))
    expect(status).toBe(400)
    expect(body.error).toBe(error)
  })

  test('a null value is stored as null', async () => {
    const { status, calls } = await run(post({ samples: [sample({ value: null })] }))
    expect(status).toBe(200)
    expect(calls.device[0][0].value).toBeNull()
  })
})
