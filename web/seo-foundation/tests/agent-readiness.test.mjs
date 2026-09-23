#!/usr/bin/env node
/**
 * Tests for seo-foundation/lib/agent-readiness/ - node:test.
 * negotiate.mjs is exercised through handleAgentRequest() with fake next()
 * and fake asset fetchers standing in for the Pages runtime, so the WIRING
 * (which branch answers which Accept header) is under test, not only helpers.
 */
import { test, describe } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {
  parseAccept,
  prefersMarkdown,
  markdownPathFor,
  appendVary,
  handleAgentRequest,
} from '../lib/agent-readiness/negotiate.mjs';
import {
  htmlToMarkdownDoc,
  buildMarkdownMirror,
} from '../lib/agent-readiness/build-markdown-mirror.mjs';

const ORIGIN = 'https://example.test';
const PAGE_HTML = '<!doctype html><html><head><title>Home</title></head><body><main><h1>Hello</h1></main></body></html>';

function html(body, status = 200) {
  return new Response(body, { status, headers: { 'Content-Type': 'text/html; charset=utf-8', Vary: 'Accept-Encoding' } });
}

// A static-site asset layer: only files in `files` exist; others 404 as HTML.
function staticAssets(files) {
  return async (url) => {
    const p = new URL(url).pathname;
    if (p in files) return new Response(files[p], { status: 200, headers: { 'Content-Type': 'text/markdown' } });
    return html('<h1>404</h1>', 404);
  };
}

// An SPA asset layer: every path answers index.html with 200.
const spaAssets = async () => html(PAGE_HTML, 200);

function req(pathname, accept, method = 'GET') {
  return new Request(`${ORIGIN}${pathname}`, { method, headers: accept ? { Accept: accept } : {} });
}

const opts = { siteName: 'Example' };

describe('prefersMarkdown', () => {
  test('explicit text/markdown wins', () => assert.equal(prefersMarkdown('text/markdown'), true));
  test('browser Accept keeps HTML', () => assert.equal(
    prefersMarkdown('text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8'), false));
  test('wildcards never select markdown', () => assert.equal(prefersMarkdown('*/*'), false));
  test('q=0 refuses markdown', () => assert.equal(prefersMarkdown('text/markdown;q=0'), false));
  test('markdown ranked below html loses', () => assert.equal(prefersMarkdown('text/html, text/markdown;q=0.5'), false));
  test('markdown tied with html wins', () => assert.equal(prefersMarkdown('text/markdown, text/html'), true));
  test('parseAccept reads q values', () => assert.deepEqual(parseAccept('a/b;q=0.3, c/d'), [{ type: 'a/b', q: 0.3 }, { type: 'c/d', q: 1 }]));
});

describe('markdownPathFor', () => {
  test('root', () => assert.equal(markdownPathFor('/'), '/index.md'));
  test('trailing slash', () => assert.equal(markdownPathFor('/about/'), '/about/index.md'));
  test('no trailing slash', () => assert.equal(markdownPathFor('/about'), '/about/index.md'));
  test('.html page', () => assert.equal(markdownPathFor('/x/page.html'), '/x/page.md'));
  test('other assets are never shadowed', () => assert.equal(markdownPathFor('/llms.txt'), null));
});

describe('appendVary', () => {
  test('adds to existing', () => assert.equal(appendVary(new Headers({ Vary: 'Accept-Encoding' }), 'Accept').get('Vary'), 'Accept-Encoding, Accept'));
  test('no duplicate', () => assert.equal(appendVary(new Headers({ Vary: 'accept' }), 'Accept').get('Vary'), 'accept'));
});

describe('handleAgentRequest on a static site', () => {
  const assets = staticAssets({ '/index.md': '# Home\n\nWelcome to the example site.' });

  test('homepage + Accept: text/markdown -> 200 markdown with Vary: Accept', async () => {
    const res = await handleAgentRequest(req('/', 'text/markdown'), async () => html(PAGE_HTML), assets, opts);
    assert.equal(res.status, 200);
    assert.match(res.headers.get('Content-Type'), /^text\/markdown/);
    assert.match(res.headers.get('Vary'), /Accept/);
    assert.match(await res.text(), /Welcome to the example site/);
  });

  test('homepage + Accept: text/html -> unchanged HTML with Vary: Accept appended', async () => {
    const res = await handleAgentRequest(req('/', 'text/html'), async () => html(PAGE_HTML), assets, opts);
    assert.equal(res.status, 200);
    assert.match(res.headers.get('Content-Type'), /^text\/html/);
    assert.equal(res.headers.get('Vary'), 'Accept-Encoding, Accept');
    assert.match(await res.text(), /<h1>Hello<\/h1>/);
  });

  test('unknown path + markdown -> 404 markdown body linking llms.txt and sitemap', async () => {
    const res = await handleAgentRequest(req('/nope', 'text/markdown'), async () => html('<h1>404</h1>', 404), assets, opts);
    assert.equal(res.status, 404);
    assert.match(res.headers.get('Content-Type'), /^text\/markdown/);
    assert.match(res.headers.get('Vary'), /Accept/);
    const body = await res.text();
    assert.ok(body.length >= 20);
    assert.match(body, /\/llms\.txt/);
    assert.match(body, /\/sitemap\.xml/);
  });

  test('unknown path + html keeps the 404 status', async () => {
    const res = await handleAgentRequest(req('/nope', 'text/html'), async () => html('<h1>404</h1>', 404), assets, opts);
    assert.equal(res.status, 404);
    assert.match(res.headers.get('Content-Type'), /^text\/html/);
  });

  test('real page without a markdown twin falls back to HTML, not a false 404', async () => {
    const res = await handleAgentRequest(req('/about/', 'text/markdown'), async () => html(PAGE_HTML), assets, opts);
    assert.equal(res.status, 200);
    assert.match(res.headers.get('Content-Type'), /^text\/html/);
  });

  test('HEAD returns headers with no body', async () => {
    const res = await handleAgentRequest(req('/', 'text/markdown', 'HEAD'), async () => html(''), assets, opts);
    assert.equal(res.status, 200);
    assert.match(res.headers.get('Content-Type'), /^text\/markdown/);
    assert.equal(res.body, null);
  });

  test('POST passes straight through', async () => {
    const passthrough = new Response('ok', { status: 201 });
    const res = await handleAgentRequest(req('/', 'text/markdown', 'POST'), async () => passthrough, assets, opts);
    assert.equal(res, passthrough);
  });
});

describe('handleAgentRequest on an SPA (every asset answers index.html 200)', () => {
  const spaOpts = { siteName: 'Example', isKnownRoute: (p) => ['/', '/about'].includes(p.replace(/\/$/, '') || '/') };

  test('missing .md twin answered with index.html is NOT served as markdown', async () => {
    const res = await handleAgentRequest(req('/about', 'text/markdown'), async () => html(PAGE_HTML), spaAssets, spaOpts);
    assert.match(res.headers.get('Content-Type'), /^text\/html/);
  });

  test('unknown route + html -> app shell with a real 404 status', async () => {
    const res = await handleAgentRequest(req('/__probe', 'text/html'), async () => html(PAGE_HTML), spaAssets, spaOpts);
    assert.equal(res.status, 404);
    assert.match(await res.text(), /<main>/);
  });

  test('unknown route + markdown -> 404 markdown', async () => {
    const res = await handleAgentRequest(req('/__probe', 'text/markdown'), async () => html(PAGE_HTML), spaAssets, spaOpts);
    assert.equal(res.status, 404);
    assert.match(res.headers.get('Content-Type'), /^text\/markdown/);
  });

  test('known route + html stays 200', async () => {
    const res = await handleAgentRequest(req('/about', 'text/html'), async () => html(PAGE_HTML), spaAssets, spaOpts);
    assert.equal(res.status, 200);
  });
});

describe('build-markdown-mirror', () => {
  test('keeps the h1 inside an article header, drops nav/script, absolutizes links', () => {
    const page = `<!doctype html><html><head><title>About Us</title>
      <meta name="description" content="Who we are &amp; why">
      <link rel="canonical" href="https://example.test/about/"></head>
      <body><nav><a href="/x">Nav link</a></nav>
      <main><article><header><h1>About Example</h1></header>
      <p>We help <a href="/venues/">families</a>.</p><script>alert(1)</script>
      <nav>inner nav</nav></article></main><footer>Footer text</footer></body></html>`;
    const md = htmlToMarkdownDoc(page, { origin: ORIGIN, pagePath: '/about/' });
    assert.match(md, /^---\ntitle: "About Us"\ndescription: "Who we are & why"\nurl: "https:\/\/example.test\/about\/"\n---/);
    assert.match(md, /# About Example/);
    assert.match(md, /\[families\]\(https:\/\/example\.test\/venues\/\)/);
    assert.doesNotMatch(md, /Nav link|inner nav|alert\(1\)|Footer text/);
  });

  test('drops UI states hidden at every breakpoint, keeps responsive content', () => {
    const page = `<html><head><title>T</title></head><body><main><h1>Hi</h1>
      <div class="hidden text-red-600">Something went wrong</div>
      <p hidden>Secret state</p><span aria-hidden="true">icon</span>
      <p class="hidden md:block">Desktop copy</p><p>Visible copy</p><img src="/x.png" alt="photo alt"></main></body></html>`;
    const md = htmlToMarkdownDoc(page, { origin: ORIGIN, pagePath: '/' });
    assert.doesNotMatch(md, /Something went wrong|Secret state|icon|photo alt|x\.png/);
    assert.match(md, /Desktop copy/);
    assert.match(md, /Visible copy/);
  });

  test('adds a title heading when the content has none', () => {
    const md = htmlToMarkdownDoc('<html><head><title>T</title></head><body><main><p>Body copy</p></main></body></html>', { origin: ORIGIN, pagePath: '/' });
    assert.match(md, /\n# T\n\nBody copy\n$/);
  });

  test('writes twins, skips 404 and noindex pages', () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'md-mirror-'));
    fs.mkdirSync(path.join(dir, 'about'));
    fs.mkdirSync(path.join(dir, 'auth'));
    fs.writeFileSync(path.join(dir, 'index.html'), PAGE_HTML);
    fs.writeFileSync(path.join(dir, 'about', 'index.html'), PAGE_HTML);
    fs.writeFileSync(path.join(dir, 'page.html'), PAGE_HTML);
    fs.writeFileSync(path.join(dir, '404.html'), PAGE_HTML);
    fs.writeFileSync(path.join(dir, 'auth', 'index.html'), '<html><head><meta name="robots" content="noindex, nofollow"></head><body>x</body></html>');
    const { written, skipped } = buildMarkdownMirror(dir, { origin: ORIGIN });
    assert.deepEqual(written.sort(), ['about/index.html', 'index.html', 'page.html']);
    assert.deepEqual(skipped.sort(), ['404.html', 'auth/index.html']);
    assert.ok(fs.existsSync(path.join(dir, 'index.md')));
    assert.ok(fs.existsSync(path.join(dir, 'about', 'index.md')));
    assert.ok(fs.existsSync(path.join(dir, 'page.md')));
    assert.ok(!fs.existsSync(path.join(dir, '404.md')));
  });

  test('exclude prefixes skip whole directories and the file cap is reported', () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'md-mirror-'));
    fs.mkdirSync(path.join(dir, 'venues', 'a'), { recursive: true });
    fs.writeFileSync(path.join(dir, 'index.html'), PAGE_HTML);
    fs.writeFileSync(path.join(dir, 'venues', 'a', 'index.html'), PAGE_HTML);
    const r = buildMarkdownMirror(dir, { origin: ORIGIN, exclude: ['/venues/'], fileLimit: 3 });
    assert.deepEqual(r.written, ['index.html']);
    assert.deepEqual(r.excluded, ['venues/a/index.html']);
    assert.ok(!fs.existsSync(path.join(dir, 'venues', 'a', 'index.md')));
    assert.equal(r.totalFiles, 3);
    assert.equal(r.overLimit, false);
    assert.equal(buildMarkdownMirror(dir, { origin: ORIGIN, exclude: ['/venues/'], fileLimit: 2 }).overLimit, true);
  });
});
