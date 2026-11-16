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
  let release: (() => void) | undefined
  let holdIssue = false
  const keys = [
    { id: 'older', label: 'Older', key_prefix: 'h4a_old', last_used_at: null, revoked_at: null as string | null },
    { id: 'issued', label: 'New', key_prefix: 'h4a_new', last_used_at: null, revoked_at: null as string | null },
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
        if (holdIssue) await new Promise<void>(resolve => { release = resolve })
        return { status: 201, ok: true, json: async () => ({ id: 'issued', key: 'h4a_SYNTHETIC' }) }
      }
      return { status: 200, ok: true, json: async () => ({ keys, person_id: 'fixture' }) }
    },
  })
  return { get, posts: () => posts, hold: () => { holdIssue = true }, release: () => release!(),
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
