import { expect, test } from 'vitest'
import { readFileSync } from 'node:fs'
import vm from 'node:vm'

class Element {
  hidden = false; disabled = false; value = 'synthetic'; textContent = ''; className = ''
  children: Element[] = []; onclick?: () => Promise<void>
  attributes = new Map<string, string>()
  append(child: Element) { this.children.push(child) }
  replaceChildren() { this.children = [] }
  addEventListener() {}
  setAttribute(k: string, v: string) { this.attributes.set(k, v) }
  removeAttribute(k: string) { this.attributes.delete(k) }
}
function fixture() {
  const elements = new Map<string, Element>()
  const get = (id: string) => {
    if (!elements.has(id)) elements.set(id, new Element())
    return elements.get(id)!
  }
  get('new-key').hidden = true
  let posts = 0
  const bodies: unknown[] = []
  let release: (() => void) | undefined
  let holdIssue = false
  let withoutScope = false
  const keys = [
    { id: 'older', label: 'Older', key_prefix: 'h4a_old', last_used_at: null, revoked_at: null as string | null },
    { id: 'issued', label: 'New', key_prefix: 'h4a_new', last_used_at: null, revoked_at: null as string | null },
    { id: 'reader', label: 'Dashboard', key_prefix: 'h4a_rd', scope: 'read', last_used_at: null, revoked_at: null as string | null },
  ]
  const script = readFileSync('public/index.html', 'utf8').split('<script>')[1].split('</script>')[0]
  vm.runInNewContext(script, {
    document: { getElementById: get, createElement: () => new Element(), addEventListener() {} },
    location: { origin: 'https://fixture.invalid' }, confirm: () => true, setTimeout,
    fetch: async (path: string, init: { method?: string }) => {
      if (path.endsWith('/revoke')) {
        keys.find(k => path.includes(k.id))!.revoked_at = 'now'
        return { status: 204 }
      }
      if (init.method === 'POST') {
        posts++
        bodies.push(JSON.parse((init as { body?: string }).body ?? 'null'))
        if (holdIssue) await new Promise<void>(resolve => { release = resolve })
        // As the API does, the issued key carries the scope it was asked for.
        const scope = withoutScope ? undefined : (bodies.at(-1) as { scope?: string } | null)?.scope
        return { status: 201, ok: true, json: async () => ({ id: 'issued', key: 'h4a_SYNTHETIC', scope }) }
      }
      return { status: 200, ok: true, json: async () => ({ keys, person_id: 'fixture' }) }
    },
  })
  return { get, posts: () => posts, bodies, answerWithoutScope: () => { withoutScope = true }, hold: () => { holdIssue = true }, release: () => release!(),
    revoke: async (index: number) => {
      const row = get('keys').children[index]
      await row.children[3].children[0].onclick!()
    } }
}

test('revoking the issued key clears the secret and copy panel', async () => {
  const f = fixture()
  await f.get('issue-btn').onclick!()
  expect(f.get('new-key').hidden).toBe(false)
  await f.revoke(1)
  expect(f.get('new-key').hidden).toBe(true)
  expect(f.get('new-key-value').textContent).toBe('')
})

test('revoking another key preserves the only copy of the new key', async () => {
  const f = fixture()
  await f.get('issue-btn').onclick!()
  await f.revoke(0)
  expect(f.get('new-key').hidden).toBe(false)
  expect(f.get('new-key-value').textContent).toBe('h4a_SYNTHETIC')
})

test('a second issue action during the request cannot mint another key', async () => {
  const f = fixture(); f.hold()
  const first = f.get('issue-btn').onclick!()
  expect(f.get('issue-btn').disabled).toBe(true)
  await f.get('issue-btn').onclick!()
  expect(f.posts()).toBe(1)
  f.release(); await first
  expect(f.get('issue-btn').disabled).toBe(false)
})

test('a key is issued with the scope picked, and a read key is marked in the list', async () => {
  const f = fixture()
  f.get('label').value = 'Dashboard'
  f.get('scope').value = 'read'
  await f.get('issue-btn').onclick!()
  expect(f.bodies).toEqual([{ label: 'Dashboard', scope: 'read' }])
  const keyCells = f.get('keys').children.map((row) => row.children[1].textContent)
  expect(keyCells).toEqual(['h4a_old…', 'h4a_new…', 'h4a_rd… (Read)'])
})

test('the issued key says its scope, and the next key goes back to Write', async () => {
  const f = fixture()
  f.get('scope').value = 'read'
  await f.get('issue-btn').onclick!()
  expect(f.get('new-key-scope').textContent).toBe('Read key')
  expect(f.get('scope').value).toBe('write')
  await f.get('issue-btn').onclick!()
  expect(f.bodies.map((b) => (b as { scope: string }).scope)).toEqual(['read', 'write'])
  expect(f.get('new-key-scope').textContent).toBe('Write key')
})

test('a key issued with another scope than the one picked is not shown, and the page says so', async () => {
  // A setup API from before scopes ignores the field and issues a write key, with no scope in its reply.
  const f = fixture()
  await f.get('issue-btn').onclick!() // an earlier key, still on screen
  expect(f.get('new-key').hidden).toBe(false)
  f.get('scope').value = 'read'
  f.answerWithoutScope()
  await f.get('issue-btn').onclick!()
  expect(f.get('new-key').hidden).toBe(true)
  expect(f.get('new-key-value').textContent).toBe('')
  expect(f.get('panel-error').hidden).toBe(false)
  expect(f.get('panel-error').textContent).toContain('not a read key')
})
