// Consent-gated loading of the site's optional third-party scripts: PostHog, Microsoft
// Clarity. NOTHING from those vendors runs, and none of their cookies or
// storage is written, until the visitor accepts in the banner (ConsentBanner.astro). Before
// this, Layout.astro injected the vendors on every production page with no consent step
// (review W1, 2026-11-04).
//
// Plain functions over an injected window/document/storage so node:test drives them
// without a browser (scripts/consent.test.mjs). ConsentBanner.astro calls startConsent.

export const CONSENT_KEY = 'h4a.consent';
/** Bump when the vendor list or what they do changes: every visitor is asked again. */
export const CONSENT_VERSION = 1;

// Non-production hosts never load the vendors (local dev and preview deployments would
// otherwise pollute the shared PostHog project 367354). Same rule the inline snippets had.
export const NON_PRODUCTION_HOST = /^([^.]+|\[.*\]|127(\.\d{1,3}){3}|0\.0\.0\.0|10(\.\d{1,3}){3}|192\.168(\.\d{1,3}){2}|172\.(1[6-9]|2\d|3[01])(\.\d{1,3}){2}|100\.(6[4-9]|[7-9]\d|1[01]\d|12[0-7])(\.\d{1,3}){2}|169\.254(\.\d{1,3}){2}|.+\.(local|localhost|ts\.net|pages\.dev|workers\.dev))$/i;

export const isProductionHost = (hostname) => !NON_PRODUCTION_HOST.test(hostname);

/** Vendor settings from the banner root's data attributes (set at build time from PUBLIC_* env). */
export function readConfig(root) {
  const get = (name) => root.getAttribute(`data-${name}`) || null;
  const key = get('posthog-key');
  const host = get('posthog-host');
  return {
    posthog: key && host ? { key, host } : null,
    clarityId: get('clarity-id'),
  };
}

export function configuredVendors(config) {
  return [
    config.posthog && 'PostHog',
    config.clarityId && 'Microsoft Clarity',
  ].filter(Boolean);
}

/**
 * The visitor's saved choice: 'granted', 'denied', or null when there is none to honour
 * (never asked, an older consent version, unreadable storage). null loads nothing.
 */
export function readChoice(storage) {
  let raw;
  try {
    raw = storage.getItem(CONSENT_KEY);
  } catch {
    return null; // storage blocked (private mode, disabled cookies): ask, and load nothing
  }
  if (!raw) return null;
  let saved;
  try {
    saved = JSON.parse(raw);
  } catch {
    return null; // not a value this code wrote: ask again
  }
  if (saved?.v !== CONSENT_VERSION) return null;
  return saved.choice === 'granted' || saved.choice === 'denied' ? saved.choice : null;
}

/** Saves the choice; false when storage refuses it (the choice then lasts for this page only). */
export function saveChoice(storage, choice, now = new Date()) {
  try {
    storage.setItem(CONSENT_KEY, JSON.stringify({ v: CONSENT_VERSION, choice, at: now.toISOString() }));
    return true;
  } catch {
    return false;
  }
}

function loadPostHog(win, doc, { key, host }) {
  // PostHog's own stub loader, unchanged apart from taking win/doc: it queues calls until
  // array.js arrives.
  !function(t,e){var o,n,p,r;e.__SV||(win.posthog=e,e._i=[],e.init=function(i,s,a){function g(t,e){var o=e.split(".");2==o.length&&(t=t[o[0]],e=o[1]),t[e]=function(){t.push([e].concat(Array.prototype.slice.call(arguments,0)))}}(p=t.createElement("script")).type="text/javascript",p.crossOrigin="anonymous",p.async=!0,p.src=s.api_host+"/static/array.js",(r=t.getElementsByTagName("script")[0]).parentNode.insertBefore(p,r);var u=e;for(void 0!==a?u=e[a]=[]:a="posthog",u.people=u.people||[],u.toString=function(t){var e="posthog";return"posthog"!==a&&(e+="."+a),t||(e+=" (stub)"),e},u.people.toString=function(){return u.toString(1)+".people (stub)"},o="capture identify alias people.set people.set_once set_config register register_once unregister opt_out_capturing has_opted_out_capturing opt_in_capturing reset isFeatureEnabled onFeatureFlags getFeatureFlag getFeatureFlagPayload reloadFeatureFlags group updateEarlyAccessFeatureEnrollment getEarlyAccessFeatures getActiveMatchingSurveys getSurveys getNextSurveyStep onSessionId".split(" "),n=0;n<o.length;n++)g(u,o[n]);e._i.push([i,s,a])},e.__SV=1)}(doc,win.posthog||[]);
  win.posthog.init(key, {
    api_host: host,
    defaults: '2026-01-30',
    capture_pageview: true,
    capture_pageleave: true,
    persistence: 'localStorage',
    session_recording: { maskAllInputs: true, maskTextSelector: '[data-ph-mask]' },
    loaded: (ph) => ph.register({ site: 'health4ai' }),
  });
}

function loadClarity(win, doc, id) {
  (function(c,l,a,r,i,t,y){c[a]=c[a]||function(){(c[a].q=c[a].q||[]).push(arguments)};t=l.createElement(r);t.async=1;t.src="https://www.clarity.ms/tag/"+i;y=l.getElementsByTagName(r)[0];y.parentNode.insertBefore(t,y)})(win,doc,"clarity","script",id);
}

/** Loads every configured vendor, once per page. Returns the names loaded. */
export function loadVendors(config, win, doc) {
  if (win.__h4aVendorsLoaded) return [];
  win.__h4aVendorsLoaded = true;
  const loaded = [];
  if (config.posthog) { loadPostHog(win, doc, config.posthog); loaded.push('PostHog'); }
  if (config.clarityId) { loadClarity(win, doc, config.clarityId); loaded.push('Microsoft Clarity'); }
  return loaded;
}

// First-party storage the vendors write after consent, removed when it is withdrawn.
const VENDOR_COOKIES = ['_clck', '_clsk'];
const VENDOR_STORAGE_PREFIXES = ['ph_', '__ph_', '_clck', '_clsk'];

/**
 * Withdrawing consent after the vendors ran on this page: tell each one to stop, remove the
 * first-party cookies and storage they set, and reload so none of their code keeps running.
 */
export function withdraw(win, doc, storage) {
  win.posthog?.opt_out_capturing?.();
  win.clarity?.('consent', false);
  const host = win.location.hostname;
  const domains = ['', `; domain=${host}`, `; domain=.${host.replace(/^www\./, '')}`];
  for (const name of VENDOR_COOKIES) {
    for (const domain of domains) doc.cookie = `${name}=; expires=Thu, 01 Jan 1970 00:00:00 GMT; path=/${domain}`;
  }
  try {
    const keys = [];
    for (let i = 0; i < storage.length; i++) keys.push(storage.key(i));
    for (const k of keys) if (VENDOR_STORAGE_PREFIXES.some((p) => k.startsWith(p))) storage.removeItem(k);
  } catch {
    // Storage unreadable: there is nothing of theirs in it to remove.
  }
  win.location.reload();
}

/**
 * Wires the banner. `root` is the banner element: data-* vendor settings, [data-consent-banner]
 * (the question), and buttons [data-consent="accept" | "decline" | "change"].
 */
export function startConsent({ root, win, doc, storage }) {
  const config = readConfig(root);
  if (configuredVendors(config).length === 0) return { state: 'no-vendors' };
  const production = isProductionHost(win.location.hostname);
  const banner = root.querySelector('[data-consent-banner]');
  const change = root.querySelector('[data-consent="change"]');
  const show = (asking) => {
    banner.hidden = !asking;
    change.hidden = asking;
  };
  const state = { choice: readChoice(storage), loaded: [] };
  const grant = () => { if (production) state.loaded = loadVendors(config, win, doc); };

  root.querySelector('[data-consent="accept"]').addEventListener('click', () => {
    state.choice = 'granted';
    saveChoice(storage, 'granted');
    show(false);
    grant();
  });
  root.querySelector('[data-consent="decline"]').addEventListener('click', () => {
    const wasLoaded = win.__h4aVendorsLoaded === true;
    state.choice = 'denied';
    saveChoice(storage, 'denied');
    show(false);
    if (wasLoaded) withdraw(win, doc, storage);
  });
  change.addEventListener('click', () => show(true));

  root.hidden = false;
  show(state.choice === null);
  if (state.choice === 'granted') grant();
  return state;
}
