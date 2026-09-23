// Shared node-stdlib-only helpers for walking a built static site and
// extracting structured data from its HTML. No site-specific values live
// here - every checker in seo-foundation/lib supplies its own config.
import fs from 'node:fs';
import path from 'node:path';

export function walkHtmlFiles(dir) {
  const out = [];
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      out.push(...walkHtmlFiles(full));
    } else if (entry.isFile() && entry.name.endsWith('.html')) {
      out.push(full);
    }
  }
  return out;
}

export function extractLdJsonBlocks(html) {
  const blocks = [];
  const re = /<script[^>]*type="application\/ld\+json"[^>]*>([\s\S]*?)<\/script>/gi;
  let m;
  while ((m = re.exec(html)) !== null) {
    blocks.push(m[1].trim());
  }
  return blocks;
}

export function hasType(node, type) {
  if (!node || typeof node !== 'object') return false;
  const t = node['@type'];
  if (Array.isArray(t)) return t.includes(type);
  return t === type;
}

export function rootNodesFromParsed(parsed) {
  if (Array.isArray(parsed)) return parsed;
  if (parsed && typeof parsed === 'object' && Array.isArray(parsed['@graph'])) return parsed['@graph'];
  return [parsed];
}

export function extractHrefs(html) {
  const hrefs = [];
  const re = /<a\s[^>]*?href=["']([^"']+)["']/gi;
  let m;
  while ((m = re.exec(html)) !== null) hrefs.push(m[1]);
  return hrefs;
}

export function extractTagHtml(html, tag) {
  const re = new RegExp(`<${tag}[\\s\\S]*?<\\/${tag}>`, 'i');
  const m = re.exec(html);
  return m ? m[0] : '';
}

// Same-origin check: hostname must match the configured site host AND the
// URL must carry no explicit port - production sites serve on the default
// port only, so any explicit port is a different origin/service.
export function isSameOrigin(url, host) {
  if (url.hostname !== host && url.hostname !== `www.${host}`) return false;
  if (url.port !== '') return false;
  return true;
}

export function normalizeHref(href, currentDirUrl, host) {
  if (!href) return null;
  if (href.startsWith('#')) return null;
  if (/^(mailto|tel|javascript):/i.test(href)) return null;

  let p;
  if (/^https?:\/\//i.test(href)) {
    let url;
    try {
      url = new URL(href);
    } catch {
      return null;
    }
    if (!isSameOrigin(url, host)) return null;
    p = url.pathname;
  } else if (href.startsWith('//')) {
    let url;
    try {
      url = new URL(`https:${href}`);
    } catch {
      return null;
    }
    if (!isSameOrigin(url, host)) return null;
    p = url.pathname;
  } else if (href.startsWith('/')) {
    p = href;
  } else {
    p = path.posix.normalize(`${currentDirUrl}${href}`);
  }
  p = p.split('#')[0].split('?')[0];
  return p;
}
