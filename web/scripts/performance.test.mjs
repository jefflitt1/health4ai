import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, statSync } from 'node:fs';
import { resolve } from 'node:path';

const root = resolve(process.env.PERF_DIST || 'dist');
const html = (route) => readFileSync(resolve(root, route, 'index.html'), 'utf8');

for (const route of ['', 'blog', 'blog/apple-health-data-schema']) {
  test(`optimized logo is wired into ${route || '/'}`, () => {
    const page = html(route);
    const logo = page.match(/<img[^>]+alt="health4.ai"[^>]*>/)?.[0];
    assert.ok(logo, 'Rendered brand image exists');
    assert.match(logo, /srcset="[^"]+ 32w,[^"]+ 64w,[^"]+ 96w"/);
    assert.match(logo, /width="32"/);
    const src = logo.match(/src="([^"]+)"/)[1];
    assert.match(src, /\.webp$/);
    assert.ok(statSync(resolve(root, `.${src}`)).size < 4000);
  });
}

test('critical hero content has no entrance delay and reduced motion is supported', () => {
  const page = html('');
  assert.ok(!/class="hero-in/.test(page), 'Critical content must render without entrance animation');
  const css = [...page.matchAll(/href="([^"]+\.css)"/g)]
    .map((match) => readFileSync(resolve(root, `.${match[1]}`), 'utf8')).join('\n') + page;
  assert.ok(/prefers-reduced-motion/.test(css), 'Reduced-motion CSS is shipped');
  assert.ok(/stroke-dashoffset:0/.test(css), 'Reduced motion leaves ECG visible');
});

const APP_STORE_URL = 'https://apps.apple.com/app/health4ai/id6783074944';

test('homepage leads with an App Store download CTA and no leftover waitlist copy', () => {
  const page = html('');
  assert.ok(page.includes(APP_STORE_URL), 'App Store URL is linked on the homepage');
  assert.match(page, /Download on the App Store/);
  assert.ok(page.includes('Not a medical device'));
  assert.ok(page.includes('Supabase only'));
  // Neon and local Docker are NOT supported backends: the app signs in with Supabase Auth and writes
  // through a Supabase Edge Function, and no other ingest path exists. This used to assert those
  // panels were present, i.e. it guarded the false claim. It now guards against it returning.
  assert.ok(!page.includes('tab-neon') && !page.includes('tab-local'), 'Neon / local Docker setup panels must not return');
  // The app has shipped: no page should still ask a visitor to join a waitlist or
  // request a TestFlight invite. WaitlistClient.astro's own submit wiring
  // (kept in the repo, unused) contains these tokens, so its absence here also
  // proves it is no longer rendered.
  for (const stale of ['Join the waitlist', 'Join waitlist', 'Notify me', 'waitlist-form', 'tf-consent', 'submitWaitlist', 'consent_testflight', 'invite-only TestFlight', 'request a beta invite', 'shared with Apple']) {
    assert.ok(!page.includes(stale), `stale waitlist/TestFlight copy must not remain: ${stale}`);
  }
});

for (const [route, label] of [
  ['setup', 'setup'],
  ['compare', 'compare'],
  ['mcp-tools', 'mcp-tools'],
  ['how-it-works', 'how-it-works'],
]) {
  test(`${label} page points its download CTA at the App Store, not a waitlist`, () => {
    const page = html(route);
    assert.ok(page.includes(APP_STORE_URL), `${route} links the App Store`);
    assert.ok(!page.includes('Join the waitlist') && !page.includes('Join waitlist'), `${route} has no waitlist CTA`);
  });
}
