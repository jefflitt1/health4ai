// Database access for ingest and setup. Every function takes a `Queryable` (a pg Pool or Client)
// so tests can run the same SQL against a local database that production runs against Netlify
// Database.

import type { MergedHourRow, MetricRow } from './ingest.ts'
import { generateDeviceKey, hashDeviceKey } from './keys.ts'

export interface Queryable {
  query<R extends Record<string, unknown> = Record<string, unknown>>(
    text: string,
    params?: unknown[],
  ): Promise<{ rows: R[]; rowCount: number | null }>
}

/**
 * The setup secret. A migration creates it; if the Owner deleted the row to replace it, a new one
 * is stored here. A plain read first, so the usual request writes nothing. When the row is gone,
 * the insert is a no-op if a concurrent request stored one first (it waits for that commit), and
 * the second read, a new statement, sees whichever row won. No endpoint returns this value.
 */
export async function setupSecret(db: Queryable): Promise<string> {
  const read = async () =>
    (await db.query<{ secret: string }>('SELECT secret FROM setup_secret')).rows[0]?.secret
  const stored = await read()
  if (stored) return stored
  await db.query('INSERT INTO setup_secret (secret) VALUES (gen_random_uuid()::text) ON CONFLICT (id) DO NOTHING')
  const made = await read()
  if (!made) throw new Error('setup_secret is still empty after storing a new secret')
  return made
}

/**
 * The person a Device key belongs to, or null. Records when the key was last used, at most once an
 * hour: a backfill sends thousands of batches, and rewriting the key's row on each one would only
 * churn it.
 */
export async function personForDeviceKey(db: Queryable, plaintext: string): Promise<string | null> {
  const { rows } = await db.query<{ person_id: string }>(
    `WITH k AS (
       SELECT id, person_id FROM device_keys WHERE key_hash = $1 AND revoked_at IS NULL
     ), touched AS (
       UPDATE device_keys d SET last_used_at = now() FROM k
        WHERE d.id = k.id AND (d.last_used_at IS NULL OR d.last_used_at < now() - interval '1 hour')
     )
     SELECT person_id FROM k`,
    [hashDeviceKey(plaintext)],
  )
  return rows[0]?.person_id ?? null
}

/**
 * One statement, so the batch is atomic. On conflict every column the app sent is overwritten,
 * which is what the Supabase upsert (ignoreDuplicates: false) did.
 */
export async function upsertDeviceRows(db: Queryable, rows: MetricRow[]): Promise<number> {
  const { rowCount } = await db.query(
    `INSERT INTO healthkit_metrics
       (user_id, metric_type, value, unit, source_device, started_at, ended_at, metadata)
     SELECT r.user_id, r.metric_type, r.value, r.unit, r.source_device, r.started_at, r.ended_at, r.metadata
       FROM jsonb_to_recordset($1::jsonb) AS r(
         user_id uuid, metric_type text, value float8, unit text, source_device text,
         started_at timestamptz, ended_at timestamptz, metadata jsonb)
     ON CONFLICT (user_id, metric_type, source_device, started_at) DO UPDATE SET
       value = EXCLUDED.value, unit = EXCLUDED.unit, ended_at = EXCLUDED.ended_at,
       metadata = EXCLUDED.metadata, synced_at = now()`,
    [JSON.stringify(rows)],
  )
  return rowCount ?? 0
}

export async function replaceMergedHours(
  db: Queryable,
  userId: string,
  rows: MergedHourRow[],
): Promise<{ written: number; deleted: number }> {
  const { rows: result } = await db.query<{ written_count: string; deleted_count: string }>(
    'SELECT written_count, deleted_count FROM health4ai_replace_merged_hours($1::uuid, $2::jsonb)',
    [userId, JSON.stringify(rows)],
  )
  // No result row is a failure, not zero: the function always returns exactly one.
  if (result.length !== 1) throw Object.assign(new Error('replace returned no row'), { code: 'no_result' })
  return { written: Number(result[0].written_count), deleted: Number(result[0].deleted_count) }
}

/** The Owner's person ID, creating the Owner on first use. */
export async function ensureOwner(db: Queryable): Promise<string> {
  await db.query(
    `INSERT INTO people (is_owner, display_name) VALUES (true, 'Owner')
     ON CONFLICT (is_owner) WHERE is_owner DO NOTHING`,
  )
  const { rows } = await db.query<{ id: string }>('SELECT id FROM people WHERE is_owner')
  return rows[0].id
}

export type DeviceKeySummary = {
  id: string
  label: string
  key_prefix: string
  created_at: string
  last_used_at: string | null
  revoked_at: string | null
}

export async function issueDeviceKey(db: Queryable, personId: string, label: string) {
  const key = generateDeviceKey()
  const { rows } = await db.query<{ id: string }>(
    `INSERT INTO device_keys (person_id, key_hash, key_prefix, label)
     VALUES ($1, $2, $3, $4) RETURNING id`,
    [personId, key.hash, key.displayPrefix, label],
  )
  return { id: rows[0].id, key: key.plaintext, key_prefix: key.displayPrefix, label }
}

export async function listDeviceKeys(db: Queryable, personId: string): Promise<DeviceKeySummary[]> {
  const { rows } = await db.query<DeviceKeySummary>(
    `SELECT id, label, key_prefix, created_at, last_used_at, revoked_at
       FROM device_keys WHERE person_id = $1 ORDER BY created_at DESC`,
    [personId],
  )
  return rows
}

/** Revokes one of this person's keys; returns false when no such active key exists. */
export async function revokeDeviceKey(db: Queryable, personId: string, keyId: string): Promise<boolean> {
  const { rowCount } = await db.query(
    `UPDATE device_keys SET revoked_at = now()
      WHERE id = $1 AND person_id = $2 AND revoked_at IS NULL`,
    [keyId, personId],
  )
  return (rowCount ?? 0) > 0
}
