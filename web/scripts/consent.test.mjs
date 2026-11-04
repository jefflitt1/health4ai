// Consent-gated vendor loading (src/lib/consent.mjs), driven with a fake DOM: what loads before
// and after a choice, what is stored, and what withdrawing removes (review W1, 2026-11-04).
import test from 'node:test';
import assert from 'node:assert/strict';
import { CONSENT_KEY, CONSENT_VERSION, readChoice, startConsent } from '../src/lib/consent.mjs';

class FakeElement {
  constructor(doc, tag, attrs = {}) {
    Object.assign(this, { doc, tagName: tag.toUpperCase(), attrs, hidden: false, listeners: {}, parentNode: null });
  }
  getAttribute(name) { return name in this.attrs ? this.attrs[name] : null; }
  addEventListener(type, fn) { (this.listeners[type] ||= []).push(fn); }
  click() { for (const fn of this.listeners.click || []) fn(); }
  insertBefore(node) { node.parentNode = this; this.doc.inserted.push(node); }
  querySelector(selector) { return this.parts?.[selector] ?? null; }
}

function fakeStorage(initial = {}, { throws = false } = {}) {
  const map = new Map(Object.entries(initial));
  const guard = () => { if (throws) throw new Error('SecurityError: storage disabled'); };
  return {
    map,
    get length() { guard(); return map.size; },
    key(i) { guard(); return [...map.keys()][i] ?? null; },
    getItem(k) { guard(); return map.has(k) ? map.get(k) : null; },
    setItem(k, v) { guard(); map.set(k, String(v)); },
    removeItem(k) { guard(); map.delete(k); },
  };
}

const ALL = {
  'data-posthog-key': 'phc_test',
  'data-posthog-host': 'https://us.i.posthog.com',
  'data-clarity-id': 'clar_test',
  'data-meta-pixel-id': '123456',
};

function setup({ host = 'health4.ai', attrs = ALL, storage = fakeStorage() } = {}) {
  const doc = { inserted: [], cookies: [] };
  Object.defineProperty(doc, 'cookie', { set(v) { doc.cookies.push(v); }, get() { return ''; } });
  const head = new FakeElement(doc, 'head');
  const firstScript = new FakeElement(doc, 'script');
  firstScript.parentNode = head;
  doc.createElement = (tag) => new FakeElement(doc, tag);
  doc.getElementsByTagName = (tag) => (tag === 'script' ? [firstScript] : []);
  const win = { reloads: 0, location: { hostname: host, reload() { win.reloads += 1; } } };
  const root = new FakeElement(doc, 'div', attrs);
  root.hidden = true;
  const button = (name) => new FakeElement(doc, 'button', { 'data-consent': name });
  root.parts = {
    '[data-consent-banner]': new FakeElement(doc, 'section'),
    '[data-consent="accept"]': button('accept'),
    '[data-consent="decline"]': button('decline'),
    '[data-consent="change"]': button('change'),
  };
  const ui = {
    banner: root.parts['[data-consent-banner]'],
    accept: root.parts['[data-consent="accept"]'],
    decline: root.parts['[data-consent="decline"]'],
    change: root.parts['[data-consent="change"]'],
  };
  const start = () => startConsent({ root, win, doc, storage });
  return { doc, win, root, storage, ui, start, loaded: () => doc.inserted.map((s) => s.src) };
}

const saved = (choice, v = CONSENT_VERSION) => fakeStorage({ [CONSENT_KEY]: JSON.stringify({ v, choice, at: '2026-11-04T00:00:00Z' }) });
const VENDOR_SCRIPTS = [
  'https://us.i.posthog.com/static/array.js',
  'https://www.clarity.ms/tag/clar_test',
  'https://connect.facebook.net/en_US/fbevents.js',
];

test('first visit: the banner asks and nothing from any vendor loads', () => {
  const t = setup();
  t.start();
  assert.equal(t.root.hidden, false);
  assert.equal(t.ui.banner.hidden, false, 'banner shown');
  assert.equal(t.ui.change.hidden, true);
  assert.deepEqual(t.loaded(), [], 'no vendor script inserted');
  assert.equal(t.win.posthog, undefined);
  assert.equal(t.win.clarity, undefined);
  assert.equal(t.win.fbq, undefined);
  assert.deepEqual(t.doc.cookies, []);
  assert.deepEqual([...t.storage.map.keys()], [], 'nothing stored before a choice');
});

test('accept loads every configured vendor once and remembers the choice', () => {
  const t = setup();
  t.start();
  t.ui.accept.click();
  assert.deepEqual(t.loaded(), VENDOR_SCRIPTS);
  assert.equal(t.ui.banner.hidden, true);
  assert.equal(t.ui.change.hidden, false);
  assert.equal(readChoice(t.storage), 'granted');
  assert.deepEqual(t.win.posthog._i[0].slice(0, 1), ['phc_test'], 'PostHog initialised with the project key');
  assert.deepEqual(t.win.fbq.queue.map((a) => [...a]), [['init', '123456'], ['track', 'PageView']]);
  t.ui.accept.click();
  assert.equal(t.loaded().length, 3, 'a second accept does not load anything twice');
});

test('a saved accept loads on the next page without asking', () => {
  const t = setup({ storage: saved('granted') });
  t.start();
  assert.deepEqual(t.loaded(), VENDOR_SCRIPTS);
  assert.equal(t.ui.banner.hidden, true);
  assert.equal(t.ui.change.hidden, false, 'the choice can still be changed');
});

test('decline loads nothing, is remembered, and is not asked again', () => {
  const t = setup();
  t.start();
  t.ui.decline.click();
  assert.deepEqual(t.loaded(), []);
  assert.equal(readChoice(t.storage), 'denied');
  assert.equal(t.win.reloads, 0, 'nothing ran, so nothing to reload');
  const next = setup({ storage: t.storage });
  next.start();
  assert.deepEqual(next.loaded(), []);
  assert.equal(next.ui.banner.hidden, true);
});

test('unreadable storage: ask, load nothing until accepted, and accept still works for the page', () => {
  const t = setup({ storage: fakeStorage({}, { throws: true }) });
  t.start();
  assert.equal(t.ui.banner.hidden, false);
  assert.deepEqual(t.loaded(), []);
  t.ui.accept.click();
  assert.deepEqual(t.loaded(), VENDOR_SCRIPTS);
});

test('a choice from an older consent version, or a value this code did not write, is asked again', () => {
  for (const storage of [saved('granted', CONSENT_VERSION - 1), fakeStorage({ [CONSENT_KEY]: 'yes' }), saved('maybe')]) {
    const t = setup({ storage });
    t.start();
    assert.equal(t.ui.banner.hidden, false);
    assert.deepEqual(t.loaded(), []);
  }
});

test('preview and local hosts never load a vendor, even after accept', () => {
  for (const host of ['localhost', '127.0.0.1', 'abc123.health4ai.pages.dev', 'mac.local']) {
    const t = setup({ host, storage: saved('granted') });
    t.start();
    t.ui.accept.click();
    assert.deepEqual(t.loaded(), [], host);
  }
});

test('only the configured vendors load', () => {
  const t = setup({ attrs: { 'data-clarity-id': 'clar_test' } });
  t.start();
  t.ui.accept.click();
  assert.deepEqual(t.loaded(), ['https://www.clarity.ms/tag/clar_test']);
  assert.equal(t.win.posthog, undefined);
  assert.equal(t.win.fbq, undefined);
  const keyOnly = setup({ attrs: { 'data-posthog-key': 'phc_test' } });
  assert.equal(keyOnly.start().state, 'no-vendors', 'PostHog needs both its key and its host');
});

test('no vendor configured: no banner and nothing wired', () => {
  const t = setup({ attrs: {} });
  assert.equal(t.start().state, 'no-vendors');
  assert.equal(t.root.hidden, true);
  assert.deepEqual(t.loaded(), []);
});

test('withdrawing after accept stops each vendor, removes their storage and reloads', () => {
  const storage = saved('granted');
  storage.setItem('ph_phc_test_posthog', '{"distinct_id":"x"}');
  storage.setItem('_clck', 'abc');
  storage.setItem('unrelated', 'kept');
  const t = setup({ storage });
  t.start();
  assert.equal(t.loaded().length, 3);
  t.ui.change.click();
  assert.equal(t.ui.banner.hidden, false, 'Cookie choices reopens the banner');
  t.ui.decline.click();
  assert.ok(t.win.posthog.some((call) => call[0] === 'opt_out_capturing'), 'PostHog told to stop capturing');
  assert.deepEqual([...t.win.clarity.q.at(-1)], ['consent', false], 'Clarity consent withdrawn');
  assert.deepEqual([...t.win.fbq.queue.at(-1)], ['consent', 'revoke'], 'Meta Pixel consent revoked');
  for (const name of ['_fbp', '_clck', '_clsk']) {
    assert.ok(t.doc.cookies.some((c) => c.startsWith(`${name}=;`) && c.includes('expires=Thu, 01 Jan 1970')), `${name} cookie expired`);
  }
  assert.deepEqual([...storage.map.keys()].sort(), [CONSENT_KEY, 'unrelated'].sort(), 'vendor storage removed, choice kept');
  assert.equal(readChoice(storage), 'denied');
  assert.equal(t.win.reloads, 1, 'reloaded so no vendor code keeps running');
});
