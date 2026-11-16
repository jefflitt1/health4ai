import { handler, TYPES, validate } from './handler.ts'
const U = '11111111-1111-1111-1111-111111111111'
const W = '22222222-2222-2222-2222-222222222222'
const E = '33333333-3333-3333-3333-333333333333'
const sample = { sample_uuid: U, metric_type: TYPES[0], value: 80, unit: 'count/min',
  source_device: 'test', started_at: '2026-11-16T10:00:00Z', ended_at: '2026-11-16T10:00:01Z' }
const begin = { operation: 'begin', workout_uuid: W, export_uuid: E, query_types: [TYPES[0]] }
function assert(x: unknown, message = 'assertion failed'): asserts x { if (!x) throw new Error(message) }
function request(body: unknown, headers: Record<string, string> = {}) {
  return new Request('https://example.invalid', { method: 'POST', headers: { Authorization: 'Bearer fake', ...headers },
    body: JSON.stringify(body) })
}
Deno.test('default off does not authenticate or access DB', async () => {
  const h = handler({ enabled: false, authenticate: () => { throw Error('called') }, rpc: () => { throw Error('called') } })
  assert((await h(request(begin))).status === 404)
})
Deno.test('JWT user stamps every RPC; payload user override is refused', async () => {
  const calls: unknown[] = []
  const h = handler({ enabled: true, authenticate: async token => { assert(token === 'fake'); return U },
    rpc: async args => { calls.push(args); return { data: { complete: false }, error: null } } })
  assert((await h(request(begin))).status === 200)
  assert((calls[0] as Record<string, unknown>).p_user_id === U)
  assert((await h(request({ ...begin, user_id: W }))).status === 400)
  assert(calls.length === 1)
})
Deno.test('missing/bad auth stops RPC', async () => {
  const h = handler({ enabled: true, authenticate: async () => null, rpc: () => { throw Error('called') } })
  assert((await h(request(begin))).status === 401)
  assert((await h(request(begin, { Authorization: '' }))).status === 401)
})
Deno.test('capability depends on deployed RPC rather than env alone', async () => {
  const h = handler({ enabled: true, authenticate: async () => U,
    rpc: async () => ({ data: null, error: { message: 'secret provider body' } }) })
  const result = await h(request({ operation: 'capabilities' }))
  assert(result.status === 503 && !(await result.text()).includes('secret'))
})
Deno.test('all valid operations map to exact wire schema', () => {
  for (const body of [begin, { operation: 'capabilities' }, { operation: 'delete_all' },
    { operation: 'delete', workout_uuid: W },
    { operation: 'page', workout_uuid: W, export_uuid: E, samples: [sample] },
    { operation: 'finalize', workout_uuid: W, export_uuid: E, observed_count: 0 }]) assert(validate(body))
})
Deno.test('reject malformed shape, GPS metadata, UUID, types and counts', () => {
  for (const body of [null, [], 'x', {}, { ...begin, workout_uuid: 'x' },
    { ...begin, query_types: [] }, { ...begin, query_types: [TYPES[0], TYPES[0]] },
    { ...begin, query_types: ['route'] }, { ...begin, coordinates: [] },
    { operation: 'finalize', workout_uuid: W, export_uuid: E, observed_count: 1.5 }]) assert(!validate(body))
})
Deno.test('reject invalid or unbounded samples and dates', () => {
  const page = (samples: unknown[]) => ({ operation: 'page', workout_uuid: W, export_uuid: E, samples })
  assert(!validate(page([])))
  assert(!validate(page(Array(501).fill(sample))))
  for (const changes of [{ value: Infinity }, { value: null }, { metadata: {} }, { unit: '' },
    { source_device: 'x'.repeat(257) }, { started_at: '2026-02-31T00:00:00Z' },
    { ended_at: '2020-01-01T00:00:00Z' }, { ended_at: '2026-11-16T10:00:01+01:00' }])
    assert(!validate(page([{ ...sample, ...changes }])))
  assert(validate(page([{ ...sample, started_at: '2026-11-16T10:00:00.1Z' }])))
})
Deno.test('actual body cap ignores lying content length', async () => {
  let calls = 0
  const h = handler({ enabled: true, authenticate: async () => U,
    rpc: async () => { calls++; return { data: {}, error: null } } })
  const response = await h(request({ huge: 'x'.repeat(262145) }, { 'Content-Length': '1' }))
  assert(response.status === 413 && calls === 0)
})
Deno.test('known conflict status is visible; other errors stay sanitized', async () => {
  const h = handler({ enabled: true, authenticate: async () => U,
    rpc: async () => ({ data: null, error: { message: 'count_mismatch' } }) })
  const response = await h(request(begin))
  assert(response.status === 409 && (await response.json()).error === 'count_mismatch')
})
Deno.test('valid near-limit 500 sample page reaches RPC', async () => {
  let selected: unknown
  for (let length = 1; length <= 256; length++) {
    const body = { operation: 'page', workout_uuid: W, export_uuid: E,
      samples: Array.from({ length: 500 }, () => ({ ...sample, unit: 'u'.repeat(64), source_device: 'x'.repeat(length) })) }
    if (new TextEncoder().encode(JSON.stringify(body)).length <= 262144) selected = body
  }
  let calls = 0
  const h = handler({ enabled: true, authenticate: async () => U,
    rpc: async () => { calls++; return { data: { observed_count: 1 }, error: null } } })
  assert(selected !== undefined && (await h(request(selected))).status === 200 && calls === 1)
})
Deno.test('runtime entry point wires validated JWT and disabled default', async () => {
  const source = await Deno.readTextFile(new URL('./index.ts', import.meta.url))
  assert(source.includes("Deno.env.get('HEALTH4AI_WORKOUT_DETAILS_ENABLED') === 'true'"))
  assert(source.includes('admin.auth.getUser(token)'))
  assert(source.includes("admin.rpc('health4ai_workout_details_v1', args)"))
})
