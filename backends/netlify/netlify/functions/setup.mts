import type { Config } from '@netlify/functions'
import { guarded, sharedPool } from '../../src/db.ts'
import { handleSetup } from '../../src/setup.ts'

export default (req: Request) =>
  guarded('setup', () => handleSetup(req, sharedPool))

export const config: Config = {
  path: ['/api/setup', '/api/setup/*'],
  // The setup secret is the only thing between the internet and a write-capable Device key, so
  // guessing it is throttled per client. The limit counts every request, including the page's own
  // (two per unlock, issue or revoke), so it leaves room for normal use.
  // A CPAP card import sends its Samples 1000 to a request, one request at a time: about ten requests
  // for a year and a half of Nights. A larger card meets the limit and waits a minute (cpap.js).
  rateLimit: { windowLimit: 30, windowSize: 60, aggregateBy: ['ip', 'domain'] },
}
