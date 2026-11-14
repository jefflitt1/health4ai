// The shared connection pool for this function instance. Created on first use rather than at
// import, so a missing database answers a JSON 500 instead of crashing the module, which makes
// the platform return its own error page with a stack trace. Still one pool per instance.

import { getDatabase } from '@netlify/database'
import type { Queryable } from './store.ts'
import { json } from './http.ts'

let pool: Queryable | undefined

export function sharedPool(): Queryable {
  pool ??= getDatabase().pool
  return pool
}

/** Runs a handler, turning an unexpected failure into a JSON 500 that names only the error class. */
export async function guarded(name: string, run: () => Promise<Response>): Promise<Response> {
  try {
    return await run()
  } catch (err) {
    console.error(`${name} failed`, { name: (err as Error)?.name, code: (err as { code?: string })?.code })
    return json({ error: 'Internal error' }, 500)
  }
}
