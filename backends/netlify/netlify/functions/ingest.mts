import type { Config } from '@netlify/functions'
import { guarded, sharedPool } from '../../src/db.ts'
import { handleIngest } from '../../src/ingest.ts'
import { personForDeviceKey, replaceMergedHours, upsertDeviceRows } from '../../src/store.ts'

export default (req: Request) =>
  guarded('ingest', () =>
    handleIngest(req, {
      authenticate: (key) => personForDeviceKey(sharedPool(), key),
      upsertDeviceRows: (rows) => upsertDeviceRows(sharedPool(), rows),
      replaceMergedHours: (userId, rows) => replaceMergedHours(sharedPool(), userId, rows),
    }),
  )

export const config: Config = { path: '/api/ingest' }
