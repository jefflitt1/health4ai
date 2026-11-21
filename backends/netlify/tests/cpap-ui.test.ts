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
  onclick?: () => Promise<void>; onchange?: () => Promise<void>
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

function fixture() {
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
    setTimeout, Intl, Uint8Array,
    STUB_MINUTES: 5,
    pickCardFiles: (paths: string[]) => ({ str: paths.find((p) => p.endsWith('STR.edf')) ?? null, events: [], leaks: [] }),
    readLeakFile: () => { throw new Error('no leak files here') },
    // The card's "STR.edf" text names it; each card reads as one Sample carrying that name.
    readCard: (card: { str: Uint8Array }) => {
      const name = new TextDecoder().decode(card.str)
      if (name === 'bad') throw new Error('Not an EDF file')
      return { nights: [{ date: name, usageHours: 1, sessions: 1, events: 0 }], samples: [{ name }],
        stats: { nights: 1, events: 0, leakMinutes: 0, stubSessions: 0, droppedEvents: 0, droppedLeakFiles: 0, unreadable: [] } }
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
