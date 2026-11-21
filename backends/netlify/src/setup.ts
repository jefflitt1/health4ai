// Setup API behind the setup secret: shows the Owner's person ID and issues, lists and revokes
// the Owner's Device keys. It never returns the database connection string, so a leaked setup
// secret lets someone write to this Deployment but not read the health data in it.
//
//   GET  /api/setup                    -> { person_id }
//   GET  /api/setup/keys               -> { keys: [...] }
//   POST /api/setup/keys {label}       -> { id, key, key_prefix, label }   (key shown once)
//   POST /api/setup/keys/:id/revoke    -> 204, or 404 if no such active key
//   POST /api/setup/samples {samples}  -> stores Samples for the Owner, with /api/ingest's limits,
//                                         checks and response (the CPAP import page)
//   GET  /api/setup/cpap-clock         -> { clocks: [...], unrecorded }: the Machine clocks
//                                         (metadata.clock) the Owner's earlier CPAP imports were
//                                         read with, unrecorded true if some predate recording it,
//                                         so the import page can warn before an import on another
//                                         clock stores the same Nights again

import { json } from './http.ts'
import { ingestBatch } from './ingest.ts'
import { setupSecretMatches } from './keys.ts'
import {
  cpapClocks, ensureOwner, issueDeviceKey, listDeviceKeys, replaceMergedHours, revokeDeviceKey, setupSecret, upsertDeviceRows,
  type Queryable,
} from './store.ts'

export const SETUP_SECRET_HEADER = 'X-Setup-Secret'
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
const MAX_LABEL = 100

/**
 * The secret lives in the database (migration 20261019000400), so it is read before the check. A
 * request with no secret at all is refused before `getDb` is called.
 */
export async function handleSetup(req: Request, getDb: () => Queryable): Promise<Response> {
  const presented = req.headers.get(SETUP_SECRET_HEADER)
  if (!presented) return json({ error: 'Wrong setup secret' }, 403)
  const db = getDb()
  if (!setupSecretMatches(presented, await setupSecret(db))) {
    return json({ error: 'Wrong setup secret' }, 403)
  }

  const path = new URL(req.url).pathname.replace(/\/+$/, '')
  const ownerId = await ensureOwner(db)

  if (path === '/api/setup' && req.method === 'GET') {
    return json({ person_id: ownerId })
  }

  if (path === '/api/setup/samples' && req.method === 'POST') {
    return ingestBatch(req, ownerId, {
      upsertDeviceRows: (rows) => upsertDeviceRows(db, rows),
      replaceMergedHours: (userId, rows) => replaceMergedHours(db, userId, rows),
    })
  }

  if (path === '/api/setup/cpap-clock' && req.method === 'GET') {
    return json(await cpapClocks(db, ownerId))
  }

  if (path === '/api/setup/keys' && req.method === 'GET') {
    return json({ keys: await listDeviceKeys(db, ownerId) })
  }

  if (path === '/api/setup/keys' && req.method === 'POST') {
    let label = ''
    try {
      const body = await req.json()
      if (body && typeof body.label === 'string') label = body.label.trim()
    } catch {
      return json({ error: 'Body must be JSON: {"label": "..."}' }, 400)
    }
    if (label.length > MAX_LABEL) return json({ error: `Label exceeds ${MAX_LABEL} characters` }, 400)
    return json(await issueDeviceKey(db, ownerId, label), 201)
  }

  const revoke = path.match(/^\/api\/setup\/keys\/([^/]+)\/revoke$/)
  if (revoke && req.method === 'POST') {
    if (!UUID.test(revoke[1])) return json({ error: 'No such active key' }, 404)
    const revoked = await revokeDeviceKey(db, ownerId, revoke[1])
    return revoked ? new Response(null, { status: 204 }) : json({ error: 'No such active key' }, 404)
  }

  return json({ error: 'Not found' }, 404)
}
