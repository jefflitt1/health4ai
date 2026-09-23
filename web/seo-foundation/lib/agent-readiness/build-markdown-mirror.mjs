#!/usr/bin/env node
// Post-build step: write a Markdown twin next to every built HTML page so
// functions/_middleware.js (negotiate.mjs) can answer Accept: text/markdown.
//
//   dist/index.html        -> dist/index.md
//   dist/about/index.html  -> dist/about/index.md
//   dist/page.html         -> dist/page.md
//
// Skips 404.html and pages marked noindex. Content comes from <main> when
// present (falls back to <body>, then also minus header/footer/aside) with
// scripts, styles, nav, forms, media and inline SVG removed. Root-relative
// links are made absolute so an
// agent reading the Markdown out of context can still follow them.
//
// Cloudflare Pages caps a deployment at 20,000 files, and a twin per page
// doubles the HTML count. Large directories pass --exclude /venues/ (repeat
// for more prefixes); excluded pages keep answering Markdown requests with
// HTML + Vary: Accept. The build fails, rather than the deploy, if the dist
// would still exceed the cap.
//
// Usage: node build-markdown-mirror.mjs <distDir> --origin https://example.com
//          [--exclude /prefix/ ...] [--file-limit 20000]
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import TurndownService from 'turndown';
import { walkHtmlFiles } from '../html-utils.mjs';

// Removed through Turndown's DOM (nesting-safe), never by regex. header and
// footer are only dropped when there is no <main>: inside <main> an article
// <header> usually carries the page's h1.
const DROP_ALWAYS = ['script', 'style', 'noscript', 'nav', 'form', 'svg', 'template', 'iframe', 'button', 'dialog', 'img', 'picture', 'video', 'audio'];
const DROP_WITHOUT_MAIN = ['header', 'footer', 'aside'];

// Elements hidden at every breakpoint are UI states JS reveals later (form
// errors, success toasts); they are not page content. A Tailwind `hidden`
// with a responsive display override (`hidden md:block`) IS content.
const RESPONSIVE_SHOW = /(^|\s)[\w-]+:(block|flex|grid|inline|inline-block|inline-flex|table|contents)(\s|$)/;
export function isHiddenNode(node) {
  if (node.nodeType !== 1) return false;
  if (node.hasAttribute('hidden') || node.getAttribute('aria-hidden') === 'true') return true;
  const cls = node.getAttribute('class') || '';
  return /(^|\s)hidden(\s|$)/.test(cls) && !RESPONSIVE_SHOW.test(cls);
}

function firstMatch(html, re) {
  const m = re.exec(html);
  return m ? decodeEntities(m[1].trim()) : '';
}

function decodeEntities(s) {
  return s
    .replace(/&amp;/g, '&')
    .replace(/&quot;/g, '"')
    .replace(/&#39;|&#x27;/g, "'")
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>');
}

function metaContent(html, name) {
  const re = new RegExp(`<meta[^>]+(?:name|property)=["']${name}["'][^>]*>`, 'i');
  const tag = re.exec(html)?.[0];
  return tag ? decodeEntities(/content=["']([^"']*)["']/i.exec(tag)?.[1] ?? '') : '';
}

export function isNoindex(html) {
  return /noindex/i.test(metaContent(html, 'robots'));
}

function extractContent(html) {
  const main = /<main\b[^>]*>([\s\S]*)<\/main>/i.exec(html);
  if (main) return { fragment: main[1], hasMain: true };
  const body = /<body\b[^>]*>([\s\S]*?)<\/body>/i.exec(html);
  return { fragment: body ? body[1] : html, hasMain: false };
}

function absolutize(fragment, origin) {
  return fragment.replace(/\b(href|src)=(["'])\/(?!\/)/gi, `$1=$2${origin}/`);
}

function yamlString(s) {
  return JSON.stringify(s);
}

export function htmlToMarkdownDoc(html, { origin, pagePath }) {
  const turndown = new TurndownService({
    headingStyle: 'atx',
    codeBlockStyle: 'fenced',
    bulletListMarker: '-',
  });
  const { fragment, hasMain } = extractContent(html);
  // addRule, not remove(): Turndown consults its built-in rules (p, img, a...)
  // BEFORE remove(), so remove() silently fails for any tag they cover.
  const drop = new Set((hasMain ? DROP_ALWAYS : [...DROP_ALWAYS, ...DROP_WITHOUT_MAIN]).map((t) => t.toUpperCase()));
  turndown.addRule('drop-non-content', {
    filter: (node) => drop.has(node.nodeName) || isHiddenNode(node),
    replacement: () => '',
  });
  const title = firstMatch(html, /<title[^>]*>([\s\S]*?)<\/title>/i);
  const description = metaContent(html, 'description');
  const canonical = firstMatch(html, /<link[^>]+rel=["']canonical["'][^>]+href=["']([^"']+)["']/i)
    || `${origin}${pagePath}`;
  const body = turndown
    .turndown(absolutize(fragment, origin))
    .replace(/\n{3,}/g, '\n\n')
    .trim();
  const front = ['---', `title: ${yamlString(title)}`];
  if (description) front.push(`description: ${yamlString(description)}`);
  front.push(`url: ${yamlString(canonical)}`, '---', '');
  const heading = /^#\s/m.test(body) ? '' : `# ${title}\n\n`;
  return `${front.join('\n')}\n${heading}${body}\n`;
}

export function markdownFileFor(htmlFile) {
  return htmlFile.endsWith(`${path.sep}index.html`) || path.basename(htmlFile) === 'index.html'
    ? htmlFile.replace(/index\.html$/, 'index.md')
    : htmlFile.replace(/\.html$/, '.md');
}

export const PAGES_FILE_LIMIT = 20000;

function countFiles(dir) {
  let n = 0;
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    n += entry.isDirectory() ? countFiles(path.join(dir, entry.name)) : 1;
  }
  return n;
}

export function buildMarkdownMirror(distDir, { origin, exclude = [], fileLimit = PAGES_FILE_LIMIT }) {
  const written = [];
  const skipped = [];
  const excluded = [];
  for (const file of walkHtmlFiles(distDir)) {
    const rel = path.relative(distDir, file).split(path.sep).join('/');
    if (exclude.some((prefix) => `/${rel}`.startsWith(prefix))) { excluded.push(rel); continue; }
    if (rel === '404.html') { skipped.push(rel); continue; }
    const html = fs.readFileSync(file, 'utf8');
    if (isNoindex(html)) { skipped.push(rel); continue; }
    const pagePath = `/${rel.replace(/index\.html$/, '').replace(/\.html$/, '')}`;
    const md = htmlToMarkdownDoc(html, { origin, pagePath });
    fs.writeFileSync(markdownFileFor(file), md);
    written.push(rel);
  }
  const totalFiles = countFiles(distDir);
  return { written, skipped, excluded, totalFiles, overLimit: totalFiles > fileLimit };
}

function argValues(flag) {
  const out = [];
  process.argv.forEach((a, i) => { if (a === flag && process.argv[i + 1]) out.push(process.argv[i + 1]); });
  return out;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const distDir = process.argv[2];
  const oi = process.argv.indexOf('--origin');
  const origin = oi > -1 ? process.argv[oi + 1]?.replace(/\/$/, '') : '';
  if (!distDir || !origin) {
    console.error('usage: build-markdown-mirror.mjs <distDir> --origin https://example.com');
    process.exit(2);
  }
  const exclude = argValues('--exclude');
  const fileLimit = Number(argValues('--file-limit')[0] ?? PAGES_FILE_LIMIT);
  const { written, skipped, excluded, totalFiles, overLimit } = buildMarkdownMirror(distDir, { origin, exclude, fileLimit });
  if (overLimit) {
    console.error(`build-markdown-mirror: dist now holds ${totalFiles} files, over the ${fileLimit}-file Pages cap - add an --exclude prefix`);
    process.exit(1);
  }
  if (written.length === 0) {
    console.error(`build-markdown-mirror: 0 Markdown files written from ${distDir} - refusing a vacuous success`);
    process.exit(1);
  }
  if (!fs.existsSync(path.join(distDir, 'index.md'))) {
    console.error('build-markdown-mirror: no index.md for the homepage - the negotiation check scans /');
    process.exit(1);
  }
  console.log(`build-markdown-mirror: wrote ${written.length} .md files, skipped ${skipped.length} (404/noindex), excluded ${excluded.length} (${exclude.join(' ') || 'none'}); dist ${totalFiles}/${fileLimit} files`);
}
