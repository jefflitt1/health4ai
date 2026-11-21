// The CPAP import script's check of the site URL, run as a process. Expected behaviour: the setup
// secret and the Samples go only over HTTPS, except to this machine (netlify dev), and a refused URL
// stops the script before it reads the card or sends anything.

import { expect, test } from 'vitest'
import { spawnSync } from 'node:child_process'

const run = (site: string) => spawnSync(process.execPath, ['scripts/cpap-import.mjs', '/no/such/card', site], {
  env: { ...process.env, H4A_SETUP_SECRET: 'synthetic' }, encoding: 'utf8',
})

test.each(['http://example.test', 'http://health4ai.netlify.app/', 'ftp://example.test', 'not a url'])('%s is refused before the card is read', (site) => {
  const { status, stderr } = run(site)
  expect(status).toBe(2)
  expect(stderr).toContain('The site URL must start with https://')
})

test.each(['https://example.test', 'http://localhost:8888', 'http://127.0.0.1:8888', 'http://[::1]:8888'])('%s passes, and the missing card is what stops it', (site) => {
  const { status, stderr } = run(site)
  expect(stderr).not.toContain('The site URL must')
  expect(stderr).toContain('ENOENT')
  expect(status).toBe(1)
})
