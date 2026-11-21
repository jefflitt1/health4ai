// The CPAP import page's script, run against stand-in elements and a stand-in card reader. Expected
// behaviour: only the folder picked last may fill the preview, show errors, or be uploaded, however
// the reads of earlier picks finish.

import { expect, test } from 'vitest'
import { readFileSync } from 'node:fs'
import vm from 'node:vm'

class Element {
  hidden = false; disabled = false; value = 'UTC'; textContent = ''
  files: unknown[] = []
  children: Element[] = []
  onclick?: () => Promise<void>; onchange?: () => Promise<void>; oninput?: () => void
  append(child: Element) { this.children.push(child) }
  replaceChildren() { this.children = [] }
  addEventListener() {}
  setAttribute() {}
  removeAttribute() {}
}

/** A card file whose bytes arrive when `release` is called, or at once. */
function file(path: string, text: string, held = false) {
  let release = () => {}
  const bytes = new TextEncoder().encode(text).buffer
  return {
    webkitRelativePath: path, name: 'STR.edf',
    arrayBuffer: () => (held ? new Promise<ArrayBuffer>((r) => { release = () => r(bytes) }) : Promise.resolve(bytes)),
    release: () => release(),
  }
}

function fixture(stored: { clocks: string[]; unrecorded: boolean } | null = { clocks: [], unrecorded: false }) {
  const elements = new Map<string, Element>()
  const get = (id: string) => {
    if (!elements.has(id)) elements.set(id, new Element())
    return elements.get(id)!
  }
  const uploaded: unknown[][] = []
  const script = readFileSync('public/cpap.html', 'utf8').split('<script type="module">')[1].split('</script>')[0]
    .replace(/^\s*import .* from '\.\/cpap\.js'\s*$/m, '')
  vm.runInNewContext(script, {
    document: { getElementById: get, createElement: () => new Element() },
    setTimeout, Uint8Array, TextDecoder,
    // This computer's zone, whatever the machine running the tests is set to.
    Intl: { DateTimeFormat: () => ({ resolvedOptions: () => ({ timeZone: 'America/Toronto' }) }) },
    // GET /api/setup/cpap-clock answers with the clocks earlier imports used.
    fetch: async (url: string) => (stored ? { ok: url === '/api/setup/cpap-clock', status: 200, json: async () => stored } : { ok: false, status: 429, json: async () => ({}) }),
    STUB_MINUTES: 5,
    pickCardFiles: (paths: string[]) => ({ str: paths.find((p) => p.endsWith('STR.edf')) ?? null,
      settings: paths.find((p) => p.endsWith('CurrentSettings.json')) ?? null, events: [], leaks: [] }),
    // The settings file's text is the clock it records; "bad" is unreadable, "" records none.
    readCardClock: (bytes: Uint8Array) => {
      const text = new TextDecoder().decode(bytes)
      if (text === 'bad') throw new Error('The card\'s TimeZoneOffset is not ±HH:MM ("bad")')
      return text || null
    },
    wallToInstant: (_wall: number, clock: string) => { if (clock === 'Nowhere') throw new RangeError('Invalid time zone'); return 0 },
    readLeakFile: () => { throw new Error('no leak files here') },
    // The card's "STR.edf" text names it; each card reads as one Sample carrying that name.
    readCard: (card: { str: Uint8Array }) => {
      const name = new TextDecoder().decode(card.str)
      if (name === 'bad') throw new Error('Not an EDF file')
      return { nights: [{ date: name, usageHours: 1, sessions: 1, events: 0 }], samples: [{ name }],
        stats: { nights: 1, events: 0, leakMinutes: 0, stubSessions: 0, droppedEvents: 0, droppedLeakFiles: 0, unreadable: [], skippedSummaries: [] } }
    },
    uploadSamples: async (samples: unknown[]) => { uploaded.push(samples); return { inserted: samples.length, batches: 1 } },
  })
  const pick = (...files: ReturnType<typeof file>[]) => { get('folder').files = files; return get('folder').onchange!() }
  return { get, uploaded, pick }
}

test('a folder picked while an earlier one is still being read is the one previewed and uploaded', async () => {
  const f = fixture()
  const a = file('A/STR.edf', 'card A', true)
  const first = f.pick(a)
  await f.pick(file('B/STR.edf', 'card B'))
  expect(f.get('summary').textContent).toContain('card B')
  a.release(); await first
  expect(f.get('summary').textContent).toContain('card B')
  expect(f.get('result').hidden).toBe(false)
  expect(f.get('reading').hidden).toBe(true)
  await f.get('upload-btn').onclick!()
  expect(f.uploaded).toEqual([[{ name: 'card B' }]])
})

test('an earlier folder that fails late shows no error over the later one', async () => {
  const f = fixture()
  const a = file('A/STR.edf', 'bad', true)
  const first = f.pick(a)
  await f.pick(file('B/STR.edf', 'card B'))
  a.release(); await first
  expect(f.get('panel-error').hidden).toBe(true)
  expect(f.get('summary').textContent).toContain('card B')
})

test('while a later folder is being read, nothing from the earlier one can be uploaded', async () => {
  const f = fixture()
  await f.pick(file('A/STR.edf', 'card A'))
  const b = file('B/STR.edf', 'card B', true)
  const second = f.pick(b)
  expect(f.get('result').hidden).toBe(true)
  expect(f.get('reading').hidden).toBe(false)
  await f.get('upload-btn').onclick!()
  expect(f.uploaded).toEqual([])
  b.release(); await second
  await f.get('upload-btn').onclick!()
  expect(f.uploaded).toEqual([[{ name: 'card B' }]])
})

test('a folder without STR.edf picked while another is being read clears the reading status', async () => {
  const f = fixture()
  const a = file('A/STR.edf', 'card A', true)
  const first = f.pick(a)
  expect(f.get('reading').hidden).toBe(false)
  await f.pick(file('B/notes.txt', 'not a card'))
  expect(f.get('reading').hidden).toBe(true)
  expect(f.get('panel-error').hidden).toBe(false)
  a.release(); await first
  expect(f.get('reading').hidden).toBe(true)
  expect(f.get('panel-error').textContent).toContain('No STR.edf')
  expect(f.get('result').hidden).toBe(true)
})

test('the clock on the card fills the clock field and says so', async () => {
  const f = fixture()
  await f.pick(file('A/STR.edf', 'card A'), file('A/SETTINGS/CurrentSettings.json', '-05:00'))
  expect(f.get('zone').value).toBe('-05:00')
  expect(f.get('zone-note').textContent).toContain('UTC-05:00, from the card')
  expect(f.get('summary').textContent).toContain('card A')
})

test('a card without a clock keeps the computer\'s zone and says the card has none', async () => {
  const f = fixture()
  await f.pick(file('A/STR.edf', 'card A'), file('A/SETTINGS/CurrentSettings.json', ''))
  expect(f.get('zone').value).toBe('America/Toronto')
  expect(f.get('zone-note').textContent).toContain('does not record')
})

test('a clock typed before picking is kept, whatever the card says', async () => {
  const f = fixture()
  f.get('zone').value = '+01:00'; f.get('zone').oninput!()
  await f.pick(file('A/STR.edf', 'card A'), file('A/SETTINGS/CurrentSettings.json', '-05:00'))
  expect(f.get('zone').value).toBe('+01:00')
  expect(f.get('zone-note').textContent).toContain('the card says UTC-05:00')
})

test('an unreadable clock on the card is said, and the card is still read', async () => {
  const f = fixture()
  await f.pick(file('A/STR.edf', 'card A'), file('A/SETTINGS/CurrentSettings.json', 'bad'))
  expect(f.get('zone-note').textContent).toContain('TimeZoneOffset')
  expect(f.get('summary').textContent).toContain('card A')
  expect(f.get('panel-error').hidden).toBe(true)
})

test('an unknown clock is refused by name', async () => {
  const f = fixture()
  f.get('zone').value = 'Nowhere'; f.get('zone').oninput!()
  await f.pick(file('A/STR.edf', 'card A'))
  expect(f.get('panel-error').textContent).toContain('Unknown clock "Nowhere"')
  expect(f.get('result').hidden).toBe(true)
})

test.each([
  ['another clock', { clocks: ['America/Toronto'], unrecorded: false }, 'America/Toronto'],
  ['an unrecorded clock', { clocks: [], unrecorded: true }, 'unrecorded'],
])('earlier imports on %s are warned about before Upload', async (_name, stored, named) => {
  const f = fixture(stored)
  await f.pick(file('A/STR.edf', 'card A'), file('A/SETTINGS/CurrentSettings.json', '-05:00'))
  await new Promise((r) => setTimeout(r, 0))
  expect(f.get('clock-warning').hidden).toBe(false)
  expect(f.get('clock-warning').textContent).toContain(named)
})

test('earlier imports on the same clock bring no warning', async () => {
  const f = fixture({ clocks: ['-05:00'], unrecorded: false })
  await f.pick(file('A/STR.edf', 'card A'), file('A/SETTINGS/CurrentSettings.json', '-05:00'))
  await new Promise((r) => setTimeout(r, 0))
  expect(f.get('clock-warning').hidden).toBe(true)
})

test('typing the computer\'s own zone still counts as typed', async () => {
  const f = fixture()
  f.get('zone').value = 'America/Toronto'; f.get('zone').oninput!()
  await f.pick(file('A/STR.edf', 'card A'), file('A/SETTINGS/CurrentSettings.json', '-05:00'))
  expect(f.get('zone').value).toBe('America/Toronto')
})

test('the note follows a clock typed after picking', async () => {
  const f = fixture()
  await f.pick(file('A/STR.edf', 'card A'), file('A/SETTINGS/CurrentSettings.json', 'bad'))
  f.get('zone').value = '-05:00'; f.get('zone').oninput!()
  await f.get('zone').onchange!()
  expect(f.get('zone-note').textContent).toContain('Using the clock you typed (-05:00)')
})

test('a clock check that fails says so instead of showing nothing', async () => {
  const f = fixture(null)
  await f.pick(file('A/STR.edf', 'card A'), file('A/SETTINGS/CurrentSettings.json', '-05:00'))
  await new Promise((r) => setTimeout(r, 0))
  expect(f.get('clock-warning').hidden).toBe(false)
  expect(f.get('clock-warning').textContent).toContain('Could not check')
})

test('the warning says what uploading does, and promises no removal the page cannot do', async () => {
  const f = fixture({ clocks: ['America/Toronto'], unrecorded: false })
  await f.pick(file('A/STR.edf', 'card A'), file('A/SETTINGS/CurrentSettings.json', '-05:00'))
  await new Promise((r) => setTimeout(r, 0))
  expect(f.get('clock-warning').textContent).toContain('a second time')
  expect(f.get('clock-warning').textContent).not.toContain('will be removed')
})
