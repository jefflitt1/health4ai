// Built pages load no third-party tracker before consent (review W1, 2026-11-04). Runs on the
// emitted HTML in dist/. Build with the vendor env vars set to check the gated path:
//   PUBLIC_POSTHOG_PROJECT_TOKEN=phc_test PUBLIC_POSTHOG_HOST=https://us.i.posthog.com \
//   PUBLIC_CLARITY_PROJECT_ID=clar_test npm run build
// Without them (a build with no vendors) it checks that no banner or loader is emitted at all.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readdirSync, readFileSync, statSync } from 'node:fs';
import { join, resolve } from 'node:path';

const root = resolve(process.env.PERF_DIST || 'dist');

function pages(dir) {
  return readdirSync(dir).flatMap((name) => {
    const path = join(dir, name);
    if (statSync(path).isDirectory()) return pages(path);
    return name.endsWith('.html') ? [path] : [];
  });
}

const all = pages(root).map((path) => ({ path: path.slice(root.length), html: readFileSync(path, 'utf8') }));
const inlineScripts = (html) => [...html.matchAll(/<script(?![^>]*\bsrc=)([^>]*)>([\s\S]*?)<\/script>/g)]
  .filter(([, attrs]) => !/type="application\/ld\+json"/.test(attrs))
  .map(([, , body]) => body);

// What starts a vendor: its loader URL, its init call, or the no-JS pixel beacon.
const TRACKER_STARTS = [
  ['PostHog', /posthog\.init\(|\/static\/array\.js/],
  ['Microsoft Clarity', /clarity\.ms\/tag\//],
  ['Meta Pixel', /fbevents\.js|fbq\(\s*['"]init|connect\.facebook\.net/],
];

test('the build emitted pages to check', () => {
  assert.ok(all.length > 20, `expected the site's pages in ${root}, found ${all.length}`);
});

test('no page starts a tracker in inline HTML, so nothing can run before consent', () => {
  for (const { path, html } of all) {
    for (const body of inlineScripts(html)) {
      for (const [vendor, pattern] of TRACKER_STARTS) {
        assert.ok(!pattern.test(body), `${path}: inline script starts ${vendor} without waiting for consent`);
      }
    }
    assert.ok(!/<noscript>[\s\S]*?facebook\.com\/tr/.test(html), `${path}: the no-JS Meta Pixel beacon fires without consent`);
    assert.ok(!/<img[^>]+facebook\.com\/tr/.test(html), `${path}: a Meta Pixel image beacon fires without consent`);
  }
});

const configured = ['PUBLIC_POSTHOG_PROJECT_TOKEN', 'PUBLIC_CLARITY_PROJECT_ID']
  .some((name) => process.env[name]);

// Pages rendered through Layout.astro (every one has a canonical link). Files copied as-is from
// public/, such as the Search Console verification file, run no scripts.
const layoutPages = all.filter(({ html }) => html.includes('<link rel="canonical"'));

test('every page carries the consent banner when a vendor is configured, and none when not', () => {
  assert.ok(layoutPages.length > 20, 'layout pages found');
  for (const { path, html } of layoutPages) {
    const has = html.includes('id="h4a-consent"');
    if (configured) {
      assert.ok(has, `${path}: vendors are configured but the page has no consent banner`);
      assert.match(html, /data-consent="accept"/, `${path}: banner has an Accept button`);
      assert.match(html, /data-consent="decline"/, `${path}: banner has a Decline button`);
    } else {
      assert.ok(!has, `${path}: no vendor is configured, so there is nothing to ask about`);
    }
  }
});

test('the vendor loaders ship only inside the consent module', { skip: !configured && 'no vendor configured for this build' }, () => {
  const page = all.find((p) => p.path === '/index.html').html;
  const scripts = [...page.matchAll(/<script[^>]+src="(\/_astro\/[^"]+\.js)"/g)].map((m) => m[1]);
  const bundles = scripts.map((src) => readFileSync(join(root, src), 'utf8'));
  const loader = bundles.find((js) => js.includes('h4a.consent'));
  assert.ok(loader, 'the consent module is bundled and referenced by the page');
  assert.match(loader, /clarity\.ms\/tag\//, 'Clarity is loaded from the consent module');
  assert.doesNotMatch(loader, /fbevents|fbq|facebook/, 'the Meta Pixel is not in the consent module');
});
