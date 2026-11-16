import { validateRoutes } from './validation.ts'
import { handler } from '../workout-details/handler.ts'
const U = '11111111-1111-1111-1111-111111111111'
const R = '22222222-2222-2222-2222-222222222222'
const common = { workout_uuid: U, export_uuid: U }
const point = { route_uuid: R, point_index: 0, timestamp: '2026-11-16T10:00:00Z',
  latitude: 0, longitude: 0, altitude: null, horizontal_accuracy: 5, vertical_accuracy: -1 }
const page = (p: unknown) => ({ ...common, operation: 'page', points: [p] })
function assert(x: unknown): asserts x { if (!x) throw new Error('assertion failed') }
Deno.test('route quality validates unknown altitude without losing point', () => {
  assert(validateRoutes(page(point)))
  assert(validateRoutes(page({ ...point, altitude: 0, vertical_accuracy: 0 })))
  for (const change of [{ latitude: 91 }, { longitude: -181 }, { latitude: Infinity },
    { altitude: 1 }, { altitude: '1' }, { horizontal_accuracy: -1 }, { vertical_accuracy: NaN },
    { point_index: -1 }, { point_index: 0.5 }, { timestamp: '2026-02-31T00:00:00Z' },
    { coordinates: [] }]) assert(!validateRoutes(page({ ...point, ...change })))
})
Deno.test('route declarations are bounded and uniquely identified', () => {
  const begin = (routes: unknown) => ({ ...common, operation: 'begin', routes })
  assert(validateRoutes(begin([])))
  assert(validateRoutes(begin([{ route_uuid: R, source_count: 100000 }])))
  for (const rows of [[{ route_uuid: R, source_count: 100001 }],
    [{ route_uuid: R, source_count: -1 }], [{ route_uuid: R, source_count: 1 }, { route_uuid: R, source_count: 1 }],
    Array(33).fill({ route_uuid: R, source_count: 1 })]) assert(!validateRoutes(begin(rows)))
})
Deno.test('invalid counts are explicit and duplicate-free', () => {
  const final = (invalid_counts: unknown) => ({ ...common, operation: 'finalize', invalid_counts })
  assert(validateRoutes(final([{ route_uuid: R, invalid_count: 2 }])))
  assert(!validateRoutes(final([{ route_uuid: R, invalid_count: -1 }])))
  assert(!validateRoutes(final([{ route_uuid: R, invalid_count: 0 }, { route_uuid: R, invalid_count: 0 }])))
})
Deno.test('shared authenticated transport invokes route validator and stamps user', async () => {
  let calls = 0
  const h = handler({ enabled: true, validatePayload: validateRoutes, authenticate: async () => U,
    rpc: async args => { assert(args.p_user_id === U); calls++; return { data: { observed_count: 1 }, error: null } } })
  const req = (body: unknown) => new Request('https://test.invalid', { method: 'POST',
    headers: { Authorization: 'Bearer fixture' }, body: JSON.stringify(body) })
  assert((await h(req(page(point)))).status === 200)
  assert((await h(req({ ...page(point), user_id: R }))).status === 400)
  assert((await h(req({ ...common, operation: 'page', samples: [] }))).status === 400)
  assert(calls === 1)
})
Deno.test('route entry has independent off-default flag and RPC', async () => {
  const source = await Deno.readTextFile(new URL('./index.ts', import.meta.url))
  assert(source.includes("Deno.env.get('HEALTH4AI_WORKOUT_ROUTES_ENABLED') === 'true'"))
  assert(source.includes('validatePayload: validateRoutes'))
  assert(source.includes("admin.rpc('health4ai_workout_routes_v1', args)"))
})
