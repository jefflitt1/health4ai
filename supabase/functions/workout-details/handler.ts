export const TYPES = [
  'HeartRate', 'RunningSpeed', 'RunningPower', 'RunningStrideLength',
  'RunningVerticalOscillation', 'RunningGroundContactTime', 'StepCount',
].map(x => `HKQuantityTypeIdentifier${x}`)
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
const ISO = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,3})?Z$/
const MAX_BYTES = 256 * 1024
type ObjectValue = Record<string, unknown>
export interface Dependencies {
  enabled: boolean
  validatePayload?: (value: unknown) => value is ObjectValue
  authenticate: (token: string) => Promise<string | null>
  rpc: (args: ObjectValue) => Promise<{ data: unknown; error: { message: string } | null }>
}
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), {
  status, headers: { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' },
})
function object(x: unknown): x is ObjectValue {
  return !!x && typeof x === 'object' && !Array.isArray(x)
}
function keys(x: ObjectValue, names: string[]) {
  return Object.keys(x).length === names.length && names.every(k => Object.hasOwn(x, k))
}
function uuid(x: unknown): x is string { return typeof x === 'string' && UUID.test(x) }
function timestamp(x: unknown): x is string {
  if (typeof x !== 'string' || !ISO.test(x) || !Number.isFinite(Date.parse(x))) return false
  return new Date(x).toISOString() === x.replace(/Z$/, x.includes('.') ? 'Z' : '.000Z') ||
    new Date(x).toISOString() === x.replace(/\.(\d{1,2})Z$/, (_, d) => `.${d.padEnd(3, '0')}Z`)
}
export function validate(x: unknown): x is ObjectValue {
  if (!object(x)) return false
  if (x.operation === 'capabilities' || x.operation === 'delete_all') return keys(x, ['operation'])
  if (!uuid(x.workout_uuid)) return false
  if (x.operation === 'delete') return keys(x, ['operation', 'workout_uuid'])
  if (!uuid(x.export_uuid)) return false
  const common = ['operation', 'workout_uuid', 'export_uuid']
  if (x.operation === 'begin') return keys(x, [...common, 'query_types']) &&
    Array.isArray(x.query_types) && x.query_types.length > 0 && x.query_types.length <= 7 &&
    new Set(x.query_types).size === x.query_types.length && x.query_types.every(t => TYPES.includes(t))
  if (x.operation === 'finalize') return keys(x, [...common, 'observed_count']) &&
    Number.isInteger(x.observed_count) && Number(x.observed_count) >= 0 && Number(x.observed_count) <= 100000
  if (x.operation !== 'page' || !keys(x, [...common, 'samples']) || !Array.isArray(x.samples) ||
      x.samples.length < 1 || x.samples.length > 500) return false
  return x.samples.every(s => object(s) && keys(s, ['sample_uuid', 'metric_type', 'value', 'unit',
    'source_device', 'started_at', 'ended_at']) && uuid(s.sample_uuid) && TYPES.includes(String(s.metric_type)) &&
    typeof s.value === 'number' && Number.isFinite(s.value) &&
    typeof s.unit === 'string' && s.unit.length > 0 && s.unit.length <= 64 &&
    typeof s.source_device === 'string' && s.source_device.length > 0 && s.source_device.length <= 256 &&
    timestamp(s.started_at) && timestamp(s.ended_at) &&
    Date.parse(s.ended_at) >= Date.parse(s.started_at))
}
async function read(req: Request): Promise<string | null> {
  if (!req.body) return ''
  const reader = req.body.getReader()
  const chunks: Uint8Array[] = []
  let count = 0
  try {
    for (;;) {
      const { value, done } = await reader.read()
      if (done) break
      count += value.length
      if (count > MAX_BYTES) { await reader.cancel(); return null }
      chunks.push(value)
    }
  } finally { reader.releaseLock() }
  const bytes = new Uint8Array(count)
  let offset = 0
  for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.length }
  return new TextDecoder('utf-8', { fatal: true }).decode(bytes)
}
const CONFLICTS = new Set(['revision_conflict', 'revision_limit', 'export_not_found', 'immutable_export',
  'sample_conflict', 'sample_limit', 'count_mismatch', 'stale_revision', 'unqueried_type',
  'point_conflict', 'invalid_point_index'])
export function handler(deps: Dependencies) {
  return async (req: Request): Promise<Response> => {
    if (req.method !== 'POST') return json({ error: 'method_not_allowed' }, 405)
    if (!deps.enabled) return json({ error: 'feature_disabled', capabilities: [] }, 404)
    const auth = req.headers.get('Authorization')
    if (!auth?.startsWith('Bearer ') || auth.length <= 7) return json({ error: 'unauthorized' }, 401)
    try {
      const user = await deps.authenticate(auth.slice(7))
      if (!user || !uuid(user)) return json({ error: 'unauthorized' }, 401)
      let body
      try {
        const raw = await read(req)
        if (raw === null) return json({ error: 'body_too_large' }, 413)
        body = JSON.parse(raw)
      } catch { return json({ error: 'invalid_body' }, 400) }
      if (!(deps.validatePayload ?? validate)(body)) return json({ error: 'invalid_payload' }, 400)
      const { data, error } = await deps.rpc({ p_user_id: user, p_operation: body.operation,
        p_workout_uuid: body.workout_uuid ?? null, p_export_uuid: body.export_uuid ?? null, p_payload: body })
      if (error) return CONFLICTS.has(error.message)
        ? json({ error: error.message }, 409) : json({ error: 'storage_unavailable' }, 503)
      return json(data)
    } catch { return json({ error: 'service_unavailable' }, 503) }
  }
}
