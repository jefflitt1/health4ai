// Ingest: receives batched HealthKit samples from the iOS app and stores them for one person.
//
// A port of supabase/functions/healthkit-ingest/index.ts with the same request and response
// contract, so the app's SyncEngine and its merged-hours handling work unchanged. Three things
// differ: the caller is identified by a Device key instead of a Supabase JWT, storage goes
// through the `store` dependency instead of the Supabase client, and a merged hour of 0 or less
// is skipped rather than stored, counted in a `skipped_merged_hours` response field that appears
// only when it is nonzero. The comments on each check below explain the production failures that
// put it there; they are kept from the original.

import { json } from './http.ts'

export interface HealthSample {
  metric_type: string
  value: number | null
  unit: string
  source_device: string
  started_at: string
  ended_at: string | null
  metadata: Record<string, unknown> | null
}

export interface MetricRow {
  user_id: string
  metric_type: string
  value: number | null
  unit: string
  source_device: string
  started_at: string
  ended_at: string | null
  metadata: Record<string, unknown> | null
}

export interface MergedHourRow {
  metric_type: string
  value: number
  unit: string
  started_at: string
  ended_at: string
  metadata: Record<string, unknown> | null
}

export interface IngestDeps {
  /** The person a Device key belongs to, or null for an unknown or revoked key. */
  authenticate(deviceKey: string): Promise<string | null>
  /** Upserts per-device rows; returns how many rows were written. */
  upsertDeviceRows(rows: MetricRow[]): Promise<number>
  /** Replaces each merged hour's per-device rows in one transaction. */
  replaceMergedHours(userId: string, rows: MergedHourRow[]): Promise<{ written: number; deleted: number }>
}

export const MAX_BODY_BYTES = 5 * 1024 * 1024
export const MAX_SAMPLES = 1000
const MAX_METADATA_BYTES = 4 * 1024
const MAX_STR = 256
const HOUR_MS = 3_600_000

// Merged hourly totals. For activity types that several devices record at the same moment, the
// app sends HealthKit's merged sum per UTC hour under this source label instead of each
// device's samples, because summing both devices counted the same steps twice. Such an hour must
// REPLACE that hour's per-device rows, or it is summed on top of them.
// Because a merged hour stands for the hour's whole total, one of 0 or less is skipped: it is not
// written, deletes nothing, and leaves an existing merged value as it is. Stored, it would erase
// that hour's per-device rows and overwrite a real merged value. HealthKit returns an hourly total
// only for hours with samples, so a 0 almost always stands for a missing total, and a sum of
// cumulative amounts cannot be negative. A genuine 0 is rare (every sample in the hour deleted
// from Health, then a zero-amount one added); it is lost, and the hour keeps its older merged
// value or per-device rows. That is the accepted trade-off: since the iOS fix the app never sends
// a missing total as 0, while a 0 standing in for a missing total erased two years of Steps and
// Walking distance.
// Keep in step with HealthKitManager.allSourcesLabel / doubleCountedActivityIdentifiers (iOS)
// and DOUBLE_COUNTED_ACTIVITY_TYPES (scripts/import_health_export.py).
export const MERGED_SOURCE = 'HealthKit (all sources)'
const MERGED_HOUR_TYPES = new Set([
  'HKQuantityTypeIdentifierStepCount',
  'HKQuantityTypeIdentifierDistanceWalkingRunning',
  'HKQuantityTypeIdentifierDistanceCycling',
  'HKQuantityTypeIdentifierDistanceSwimming',
  'HKQuantityTypeIdentifierDistanceWheelchair',
  'HKQuantityTypeIdentifierDistanceDownhillSnowSports',
  'HKQuantityTypeIdentifierPushCount',
  'HKQuantityTypeIdentifierSwimmingStrokeCount',
  'HKQuantityTypeIdentifierFlightsClimbed',
  'HKQuantityTypeIdentifierActiveEnergyBurned',
  'HKQuantityTypeIdentifierBasalEnergyBurned',
  'HKQuantityTypeIdentifierAppleExerciseTime',
  'HKQuantityTypeIdentifierAppleMoveTime',
  'HKQuantityTypeIdentifierAppleStandTime',
])

// Reported on EVERY 2xx, including the empty batch the app sends to ask. The app sends merged
// hours only to a server that lists this.
export const CAPABILITIES = ['merged_hours_v1']

// A merged row's timestamps decide which rows are DELETED, so JavaScript and Postgres must read
// them as the same instant. Date.parse truncates past milliseconds and reads two-digit years
// differently from Postgres, so merged rows need a strict ISO-8601 form, and storage receives the
// canonical toISOString() of the checked instant rather than the client's string.
const STRICT_ISO_8601 = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,3})?(Z|[+-]\d{2}:\d{2})$/

export async function handleIngest(req: Request, deps: IngestDeps): Promise<Response> {
  if (req.method !== 'POST') {
    return new Response('Method Not Allowed', { status: 405 })
  }

  // Fast path only: a Content-Length that is present and too large is refused before any work.
  // A MISSING header is not refused: HTTP/2 does not require it and a proxy hop may drop it, and
  // the app does not retry 4xx. The real limit is enforced on the bytes that arrive.
  const contentLengthHeader = req.headers.get('content-length')
  if (contentLengthHeader !== null) {
    const contentLength = Number(contentLengthHeader)
    if (!Number.isFinite(contentLength) || contentLength > MAX_BODY_BYTES) {
      await releaseBody(req.body)
      return json({ error: 'Request body exceeds maximum size' }, 413)
    }
  }

  const authHeader = req.headers.get('Authorization')
  if (!authHeader?.startsWith('Bearer ')) {
    return json({ error: 'Missing Authorization header' }, 401)
  }
  const userId = await deps.authenticate(authHeader.slice(7))
  if (!userId) return json({ error: 'Unauthorized' }, 401)

  const bodyText = await readBodyCapped(req, MAX_BODY_BYTES)
  if (bodyText === null) {
    return json({ error: 'Request body exceeds maximum size' }, 413)
  }
  let payload: { samples?: unknown }
  try {
    payload = JSON.parse(bodyText)
  } catch {
    return json({ error: 'Invalid JSON body' }, 400)
  }
  // JSON.parse accepts `null`, arrays and scalars; none of them is a batch.
  if (payload === null || typeof payload !== 'object' || Array.isArray(payload)) {
    return json({ error: 'Body must be a JSON object' }, 400)
  }

  if (!Array.isArray(payload.samples) || payload.samples.length === 0) {
    return json({ inserted: 0, capabilities: CAPABILITIES })
  }
  if (payload.samples.length > MAX_SAMPLES) {
    return json({ error: `Batch size exceeds maximum of ${MAX_SAMPLES} samples` }, 400)
  }

  const samples = payload.samples as HealthSample[]
  for (const s of samples) {
    // A sample that is not an object, has no metric_type, or carries a non-numeric value would fail
    // in Postgres as a 500, which the app retries on every sync. Refuse it as a 400 instead.
    if (s === null || typeof s !== 'object' || Array.isArray(s)) {
      return json({ error: 'Each sample must be a JSON object' }, 400)
    }
    if (typeof s.metric_type !== 'string' || s.metric_type.length === 0) {
      return json({ error: 'metric_type must be a non-empty string' }, 400)
    }
    // Merged rows have their own, stricter value check below.
    if (s.source_device !== MERGED_SOURCE && s.value != null && (typeof s.value !== 'number' || !Number.isFinite(s.value))) {
      return json({ error: 'value must be a finite number or null' }, 400)
    }
    if (
      (s.metric_type?.length ?? 0) > MAX_STR ||
      (s.unit?.length ?? 0) > MAX_STR ||
      (s.source_device?.length ?? 0) > MAX_STR
    ) {
      return json({ error: `String field exceeds maximum length of ${MAX_STR}` }, 400)
    }
    // `!= null`: the app's synthesized Codable OMITS a nil optional, so a sample without
    // metadata arrives with the key absent. Absent means null.
    if (s.metadata != null && (typeof s.metadata !== 'object' || Array.isArray(s.metadata))) {
      return json({ error: 'Metadata must be an object or null' }, 400)
    }
    if (s.metadata && new TextEncoder().encode(JSON.stringify(s.metadata)).length > MAX_METADATA_BYTES) {
      return json({ error: 'Metadata exceeds maximum size of 4096 bytes' }, 400)
    }
    // started_at is in both the unique key and the dedup key; a malformed value would collapse
    // distinct samples or fail the whole batch in Postgres.
    if (typeof s.started_at !== 'string' || s.started_at.length > 64 || Number.isNaN(Date.parse(s.started_at))) {
      return json({ error: 'started_at must be an ISO-8601 timestamp' }, 400)
    }
    if (s.ended_at != null && (typeof s.ended_at !== 'string' || s.ended_at.length > 64 || Number.isNaN(Date.parse(s.ended_at)))) {
      return json({ error: 'ended_at must be an ISO-8601 timestamp or null' }, 400)
    }
    // A merged row deletes every per-device row whose started_at falls in its hour, so its shape
    // is enforced: exactly one whole UTC hour, of a type that is merged at all.
    if (s.source_device === MERGED_SOURCE) {
      const start = Date.parse(s.started_at)
      if (
        !MERGED_HOUR_TYPES.has(s.metric_type) ||
        !STRICT_ISO_8601.test(s.started_at) ||
        start % HOUR_MS !== 0 ||
        typeof s.ended_at !== 'string' ||
        !STRICT_ISO_8601.test(s.ended_at) ||
        Date.parse(s.ended_at) !== start + HOUR_MS
      ) {
        return json({ error: 'Merged rows must cover exactly one UTC hour of a merged activity type' }, 400)
      }
      // "NaN" or "Infinity" would be stored and poison every later sum.
      if (typeof s.value !== 'number' || !Number.isFinite(s.value)) {
        return json({ error: 'Merged rows must carry a finite numeric value' }, 400)
      }
      // A value of 0 or less passes here and is skipped after dedup (see MERGED_SOURCE) rather
      // than refused: a 400 would drop the batch's valid rows, and the app does not retry 4xx.
    }
  }

  const rows: MetricRow[] = samples.map((s) => ({
    user_id: userId,
    metric_type: s.metric_type,
    value: s.value ?? null,
    unit: s.unit,
    // '' not null: source_device is part of the unique key.
    source_device: s.source_device ?? '',
    started_at: s.started_at,
    ended_at: s.ended_at ?? null,
    metadata: s.metadata ?? null,
  }))

  // Deduplicate within the batch on the conflict key: an upsert that touches one row twice fails
  // the whole statement. started_at is normalized to epoch ms because "+00:00" and "Z" spell the
  // same instant. JSON.stringify, not a '|'-joined string, since neither field forbids '|'.
  // The last row wins, except that a merged row of 0 or less never displaces a positive one: it
  // would be skipped below and take the real total with it.
  // (Merged values were checked as finite numbers above; `?? 0` only satisfies the type.)
  const hasPositiveTotal = (row: MetricRow) => (row.value ?? 0) > 0
  const seen = new Map<string, MetricRow>()
  for (const row of rows) {
    const normTs = new Date(row.started_at).getTime()
    const key = JSON.stringify([row.metric_type, row.source_device, normTs])
    const kept = seen.get(key)
    if (kept && row.source_device === MERGED_SOURCE && !hasPositiveTotal(row) && hasPositiveTotal(kept)) continue
    seen.set(key, row)
  }

  // Per-device rows are upserted; merged rows with a positive total replace their hour; merged
  // hours of 0 or less are skipped (see MERGED_SOURCE) and only counted.
  const deviceRows: MetricRow[] = []
  const mergedRows: MetricRow[] = []
  let skippedMergedHours = 0
  for (const row of seen.values()) {
    if (row.source_device !== MERGED_SOURCE) deviceRows.push(row)
    else if (hasPositiveTotal(row)) mergedRows.push(row)
    else skippedMergedHours++
  }
  if (skippedMergedHours > 0) {
    // Count only; never row contents.
    console.warn('Skipped merged hours of 0 or less', { count: skippedMergedHours })
  }

  let inserted = 0
  let replaced = 0

  if (deviceRows.length > 0) {
    try {
      inserted += await deps.upsertDeviceRows(deviceRows)
    } catch (err) {
      // Error code only; never row contents.
      console.error('Upsert failed', { code: (err as { code?: string })?.code })
      return json({ error: 'Unable to store samples' }, 500)
    }
  }

  if (mergedRows.length > 0) {
    try {
      const result = await deps.replaceMergedHours(
        userId,
        // Canonical timestamps: the instant that passed the hour check, not the client's spelling.
        mergedRows.map(({ metric_type, value, unit, started_at, metadata }) => {
          const start = Date.parse(started_at)
          return {
            metric_type, value: value as number, unit, metadata,
            started_at: new Date(start).toISOString(),
            ended_at: new Date(start + HOUR_MS).toISOString(),
          }
        }),
      )
      inserted += result.written
      replaced += result.deleted
    } catch (err) {
      console.error('Merged hour replace failed', { code: (err as { code?: string })?.code })
      return json({ error: 'Unable to store samples' }, 500)
    }
  }

  // skipped_merged_hours only when something was skipped, so every other response keeps its shape.
  return json({
    inserted,
    replaced,
    ...(skippedMergedHours > 0 ? { skipped_merged_hours: skippedMergedHours } : {}),
    capabilities: CAPABILITIES,
  })
}

/**
 * Cancels a body stream we are refusing. A cancel that rejects means the stream had already
 * failed; that is logged, never swallowed, and must not turn an intended 413 into a 500.
 */
async function releaseBody(stream: ReadableStream<Uint8Array> | ReadableStreamDefaultReader<Uint8Array> | null): Promise<void> {
  if (!stream) return
  try {
    await stream.cancel()
  } catch (err) {
    console.error('Request body cancel failed', { name: (err as Error)?.name })
  }
}

/** Reads the request body, refusing past `max` bytes as they arrive rather than after buffering it all. */
async function readBodyCapped(req: Request, max: number): Promise<string | null> {
  if (!req.body) return ''
  const reader = req.body.getReader()
  const chunks: Uint8Array[] = []
  let total = 0
  for (;;) {
    const { done, value } = await reader.read()
    if (done) break
    total += value.byteLength
    if (total > max) {
      await releaseBody(reader)
      return null
    }
    chunks.push(value)
  }
  const bytes = new Uint8Array(total)
  let offset = 0
  for (const chunk of chunks) {
    bytes.set(chunk, offset)
    offset += chunk.byteLength
  }
  return new TextDecoder().decode(bytes)
}
