// The CPAP import script, run as a process. Expected behaviour: the setup secret and the Samples go
// only over HTTPS, except to this machine (netlify dev), and never on to where a redirect points;
// a bad URL, zone or missing secret stops the script before it reads the card or sends anything.

import { expect, test } from 'vitest'
import { execFile, spawnSync } from 'node:child_process'
import { mkdirSync, mkdtempSync, writeFileSync } from 'node:fs'
import { createServer, type Server } from 'node:http'
import type { AddressInfo } from 'node:net'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { buildEdf } from './edf-builder.ts'

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

test.each([
  ['an unknown --tz', ['--tz', 'America/Torono'], { H4A_SETUP_SECRET: 'synthetic' }, 'Unknown time zone'],
  ['no setup secret', [], { H4A_SETUP_SECRET: '' }, 'Set H4A_SETUP_SECRET'],
])('%s is refused before the card is read', (_name, args, env, message) => {
  const { status, stderr } = spawnSync(process.execPath, ['scripts/cpap-import.mjs', '/no/such/card', 'https://example.test', ...args], {
    env: { ...process.env, ...env }, encoding: 'utf8',
  })
  expect(stderr).toContain(message)
  expect(stderr).not.toContain('ENOENT')
  expect(status).toBe(2)
})

test('a redirect stops the upload: the place it points to receives nothing', async () => {
  // A one-night card: STR.edf with a session 23:00-06:00 on 2024-01-10, so there are Samples to send.
  const minutes = { physMin: 0, physMax: 1440, digMin: 0, digMax: 1440, samplesPerRecord: 20 }
  const one = (label: string, physMax: number, digMax: number, unit = '') => ({ label, physMin: 0, physMax, digMin: 0, digMax, samplesPerRecord: 1, unit })
  const slots = (...v: number[]) => [...v, ...Array(20 - v.length).fill(-1)]
  const card = join(mkdtempSync(join(tmpdir(), 'cpap-cli-')), 'CARD')
  mkdirSync(card)
  writeFileSync(join(card, 'STR.edf'), buildEdf({
    startDate: '10.01.24', startTime: '12.00.00', recordSeconds: 86400,
    signals: [{ label: 'MaskOn', ...minutes }, { label: 'MaskOff', ...minutes }, one('AHI', 240, 2400), one('Leak.95', 2, 100, 'L/s'), one('MaskPress.50', 40, 2000)],
    records: [[slots(660), slots(1080), [52], [12], [512]]],
  }))

  const listen = (server: Server) => new Promise<number>((r) => server.listen(0, '127.0.0.1', () => r((server.address() as AddressInfo).port)))
  let reached = 0
  const target = createServer((req, res) => { reached++; req.resume(); res.end('{"inserted":4}') })
  const targetPort = await listen(target)
  let redirected = 0
  const site = createServer((req, res) => {
    redirected++
    req.resume()
    res.writeHead(307, { Location: `http://127.0.0.1:${targetPort}/api/setup/samples` }).end()
  })
  const sitePort = await listen(site)
  try {
    const result = await new Promise<{ code: number | null; stderr: string }>((resolve) => {
      execFile(process.execPath, ['scripts/cpap-import.mjs', card, `http://127.0.0.1:${sitePort}`, '--tz', 'UTC'],
        { env: { ...process.env, H4A_SETUP_SECRET: 'synthetic' } },
        (err, _stdout, stderr) => resolve({ code: err ? (err as { code?: number }).code ?? 1 : 0, stderr }))
    })
    expect(redirected).toBe(1)
    expect(reached).toBe(0)
    expect(result.code).not.toBe(0)
  } finally {
    site.close(); target.close()
  }
})
