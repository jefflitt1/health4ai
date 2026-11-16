type RecordValue = Record<string, unknown>
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
function uuid(x: unknown): x is string { return typeof x === 'string' && UUID.test(x) }
function object(x: unknown): x is RecordValue { return !!x && typeof x === 'object' && !Array.isArray(x) }
function keys(x: RecordValue, names: string[]) {
  return Object.keys(x).length === names.length && names.every(k => Object.hasOwn(x, k))
}
function count(x: unknown): x is number { return Number.isInteger(x) && Number(x) >= 0 && Number(x) <= 100000 }
function finite(x: unknown): x is number { return typeof x === 'number' && Number.isFinite(x) }
function time(x: unknown): x is string {
  if (typeof x !== 'string' || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,3})?Z$/.test(x)) return false
  const normalized = x.replace(/(?:\.(\d{1,3}))?Z$/, (_, digits) => `.${(digits ?? '').padEnd(3, '0')}Z`)
  return Number.isFinite(Date.parse(x)) && new Date(x).toISOString() === normalized
}
export function validateRoutes(x: unknown): x is RecordValue {
  if (!object(x)) return false
  if (x.operation === 'capabilities' || x.operation === 'delete_all') return keys(x, ['operation'])
  if (!uuid(x.workout_uuid)) return false
  if (x.operation === 'delete') return keys(x, ['operation', 'workout_uuid'])
  if (!uuid(x.export_uuid)) return false
  const common = ['operation', 'workout_uuid', 'export_uuid']
  if (x.operation === 'begin') {
    if (!keys(x, [...common, 'routes']) || !Array.isArray(x.routes) || x.routes.length > 32) return false
    return x.routes.every(r => object(r) && keys(r, ['route_uuid', 'source_count']) && uuid(r.route_uuid) && count(r.source_count)) &&
      new Set(x.routes.map(r => r.route_uuid.toLowerCase())).size === x.routes.length &&
      x.routes.reduce((sum, r) => sum + r.source_count, 0) <= 100000
  }
  if (x.operation === 'finalize') {
    if (!keys(x, [...common, 'invalid_counts']) || !Array.isArray(x.invalid_counts) || x.invalid_counts.length > 32) return false
    return x.invalid_counts.every(r => object(r) && keys(r, ['route_uuid', 'invalid_count']) && uuid(r.route_uuid) && count(r.invalid_count)) &&
      new Set(x.invalid_counts.map(r => r.route_uuid.toLowerCase())).size === x.invalid_counts.length
  }
  if (x.operation !== 'page' || !keys(x, [...common, 'points']) || !Array.isArray(x.points) ||
      x.points.length < 1 || x.points.length > 500) return false
  return x.points.every(p => object(p) && keys(p, ['route_uuid', 'point_index', 'timestamp',
    'latitude', 'longitude', 'altitude', 'horizontal_accuracy', 'vertical_accuracy']) &&
    uuid(p.route_uuid) && count(p.point_index) && p.point_index < 100000 && time(p.timestamp) &&
    finite(p.latitude) && p.latitude >= -90 && p.latitude <= 90 &&
    finite(p.longitude) && p.longitude >= -180 && p.longitude <= 180 &&
    finite(p.horizontal_accuracy) && p.horizontal_accuracy >= 0 && finite(p.vertical_accuracy) &&
    (p.altitude === null || (finite(p.altitude) && p.vertical_accuracy >= 0)))
}
