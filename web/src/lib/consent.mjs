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
export const CONSENT_VERSION = 2;

export function browserStorage(win) {
  try { return win.localStorage; } catch { return null; }
}

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
  if (saved.choice === 'granted') {
    // Do not honor an old grant when this browser cannot save a withdrawal.
    try { storage.setItem(CONSENT_KEY, raw); } catch { return null; }
  }
  return saved.choice === 'granted' || saved.choice === 'denied' ? saved.choice : null;
}

/** Saves the choice; false when storage refuses it (the choice then lasts for this page only). */
export function saveChoice(storage, choice, now = new Date()) {
  try {
    storage.setItem(CONSENT_KEY, JSON.stringify({ v: CONSENT_VERSION, choice, at: now.toISOString() }));
    return true;
  } catch {
    if (choice === 'denied') {
      // A full/read-only store must never preserve an earlier grant across reload.
      try {
        storage.removeItem(CONSENT_KEY);
        return storage.getItem(CONSENT_KEY) === null;
      } catch { return false; }
    }
    return false;
  }
}

function loadPostHog(win, doc, { key, host }, permitted) {
  // PostHog's own stub loader, unchanged apart from taking win/doc: it queues calls until
  // array.js arrives.
  !function(t,e){var o,n,p,r;e.__SV||(win.posthog=e,e._i=[],e.init=function(i,s,a){function g(t,e){var o=e.split(".");2==o.length&&(t=t[o[0]],e=o[1]),t[e]=function(){t.push([e].concat(Array.prototype.slice.call(arguments,0)))}}(p=t.createElement("script")).type="text/javascript",p.crossOrigin="anonymous",p.async=!0,p.src=s.api_host+"/static/array.js",(r=t.getElementsByTagName("script")[0]).parentNode.insertBefore(p,r);var u=e;for(void 0!==a?u=e[a]=[]:a="posthog",u.people=u.people||[],u.toString=function(t){var e="posthog";return"posthog"!==a&&(e+="."+a),t||(e+=" (stub)"),e},u.people.toString=function(){return u.toString(1)+".people (stub)"},o="capture identify alias people.set people.set_once set_config register register_once unregister opt_out_capturing has_opted_out_capturing opt_in_capturing reset isFeatureEnabled onFeatureFlags getFeatureFlag getFeatureFlagPayload reloadFeatureFlags group updateEarlyAccessFeatureEnrollment getEarlyAccessFeatures getActiveMatchingSurveys getSurveys getNextSurveyStep onSessionId".split(" "),n=0;n<o.length;n++)g(u,o[n]);e._i.push([i,s,a])},e.__SV=1)}(doc,win.posthog||[]);
  win.posthog.init(key, {
    api_host: host,
    defaults: '2026-01-30',
    capture_pageview: false,
    capture_pageleave: false,
    autocapture: false,
    persistence: 'memory',
    person_profiles: 'never',
    disable_session_recording: true,
    before_send(event) {
      if (!permitted()) return null;
      const props = event.properties || {};
      event.properties = { site: 'health4ai', $current_url: win.location.origin + win.location.pathname, $process_person_profile: false };
      for (const key of ['token', 'distinct_id', '$device_id', '$session_id', '$window_id', 'form', 'status', 'testflight_consent', 'checked']) {
        if (['string', 'number', 'boolean'].includes(typeof props[key])) event.properties[key] = props[key];
      }
      return event;
    },
    loaded: (ph) => {
      if (!permitted()) { ph.opt_out_capturing(); return; }
      ph.register({ site: 'health4ai' }); ph.capture('$pageview');
    },
  });
}

function loadClarity(win, doc, id, permitted) {
  (function(c,l,a,r,i,t,y){c[a]=c[a]||function(){(c[a].q=c[a].q||[]).push(arguments)};t=l.createElement(r);t.async=1;t.src="https://www.clarity.ms/tag/"+i;t.onload=()=>{if(!permitted())c[a]('stop');};y=l.getElementsByTagName(r)[0];y.parentNode.insertBefore(t,y)})(win,doc,"clarity","script",id);
  win.clarity('consentv2', { ad_Storage: 'denied', analytics_Storage: 'granted' });
}

/** Loads every configured vendor, once per page. Returns the names loaded. */
export function loadVendors(config, win, doc, permitted) {
  if (!permitted()) return [];
  if (win.__h4aVendorsLoaded) return [];
  win.__h4aVendorsLoaded = true;
  const loaded = [];
  if (config.posthog) { loadPostHog(win, doc, config.posthog, permitted); loaded.push('PostHog'); }
  if (config.clarityId) { loadClarity(win, doc, config.clarityId, permitted); loaded.push('Microsoft Clarity'); }
  return loaded;
}

// First-party storage the vendors write after consent, removed when it is withdrawn.
const VENDOR_COOKIES = ['_clck', '_clsk'];
const VENDOR_STORAGE_PREFIXES = ['ph_', '__ph_', '_clck', '_clsk'];

/**
 * Withdrawing consent after the vendors ran on this page: tell each one to stop, remove the
 * first-party cookies and storage they set, and reload so none of their code keeps running.
 */
export function withdraw(win, doc, storage, reload = true) {
  // One vendor's failure must not prevent the other opt-out or local cleanup.
  try { win.posthog?.opt_out_capturing?.(); } catch { win.console?.warn('PostHog opt-out could not be confirmed'); }
  try { win.clarity?.('stop'); } catch { win.console?.warn('Clarity stop could not be confirmed'); }
  try { win.clarity?.('consentv2', { ad_Storage: 'denied', analytics_Storage: 'denied' }); }
  catch { win.console?.warn('Clarity opt-out could not be confirmed'); }
  const host = win.location.hostname;
  const domains = ['', `; domain=${host}`, `; domain=.${host.replace(/^www\./, '')}`];
  for (const name of VENDOR_COOKIES) {
    for (const domain of domains) {
      try { doc.cookie = `${name}=; expires=Thu, 01 Jan 1970 00:00:00 GMT; path=/${domain}`; }
      catch { win.console?.warn('Analytics cookie removal could not be confirmed'); }
    }
  }
  try {
    const keys = [];
    for (let i = 0; i < storage.length; i++) keys.push(storage.key(i));
    for (const k of keys) if (VENDOR_STORAGE_PREFIXES.some((p) => k.startsWith(p))) storage.removeItem(k);
  } catch {
    win.console?.warn('Analytics storage removal could not be confirmed');
  }
  if (reload) win.location.reload();
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
  const failure = root.querySelector('[data-consent-error]');
  const gpcNotice = root.querySelector('[data-consent-gpc]');
  const accept = root.querySelector('[data-consent="accept"]');
  const gpc = () => win.navigator?.globalPrivacyControl === true;
  const show = (asking) => {
    banner.hidden = !asking;
    change.hidden = asking;
    accept.disabled = gpc();
    if (gpcNotice) gpcNotice.hidden = !gpc();
  };
  const state = { choice: gpc() ? 'denied' : readChoice(storage), loaded: [], stopped: false };
  const saveDenial = () => readChoice(storage) === 'denied' || saveChoice(storage, 'denied');
  const permitted = () => production && !gpc() && !state.stopped && state.choice === 'granted';
  const grant = () => { if (permitted()) state.loaded = loadVendors(config, win, doc, permitted); };

  root.querySelector('[data-consent="accept"]').addEventListener('click', () => {
    if (failure) failure.hidden = true;
    state.choice = gpc() ? 'denied' : 'granted';
    if (!saveChoice(storage, state.choice)) {
      state.choice = 'denied'; state.stopped = true;
      show(true); if (failure) failure.hidden = false;
      if (win.__h4aVendorsLoaded) withdraw(win, doc, storage, false);
      return;
    }
    show(false);
    if (state.stopped && win.__h4aVendorsLoaded) { win.location.reload(); return; }
    state.stopped = false;
    grant();
  });
  root.querySelector('[data-consent="decline"]').addEventListener('click', () => {
    const wasLoaded = win.__h4aVendorsLoaded === true;
    state.stopped = wasLoaded;
    state.choice = 'denied';
    const saved = saveChoice(storage, 'denied');
    // If even removal fails, reloading could honor the old grant again. Keep the
    // error visible and ask for browser-level cleanup instead of claiming success.
    const blocked = wasLoaded && !saved;
    show(blocked);
    if (failure) failure.hidden = !blocked;
    if (wasLoaded) withdraw(win, doc, storage, !blocked);
  });
  change.addEventListener('click', () => show(true));
  win.addEventListener('pageshow', () => {
    if (!gpc()) return;
    state.choice = 'denied'; state.stopped = true;
    const saved = saveDenial(); show(!saved);
    if (failure) failure.hidden = saved;
    if (win.__h4aVendorsLoaded) withdraw(win, doc, storage, saved);
  });
  win.addEventListener('storage', event => {
    if (event.key !== CONSENT_KEY && event.key !== null) return;
    if (!win.__h4aVendorsLoaded) {
      state.choice = gpc() ? 'denied' : readChoice(storage); show(state.choice === null); return;
    }
    state.choice = 'denied'; state.stopped = true;
    // Another tab's updated choice is read afresh after all old SDKs are stopped.
    withdraw(win, doc, storage);
  });
  if (gpc()) saveDenial();

  root.hidden = false;
  show(state.choice === null);
  if (state.choice === 'granted') grant();
  return state;
}
