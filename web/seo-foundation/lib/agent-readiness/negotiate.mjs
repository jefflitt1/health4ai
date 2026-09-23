// Markdown content negotiation for Cloudflare Pages sites (acceptmarkdown.com
// + the Is Agentic "markdown-negotiation-vary" and "agent-friendly-404" checks).
//
// Pure functions only: no Pages or Workers globals, so node:test can exercise
// every branch. functions/_middleware.js in each site is a thin wrapper that
// passes its request, next() and env.ASSETS into handleAgentRequest().
//
// Contract (verified against the scanner's recommendation text 2026-09-23):
//   Accept: text/markdown -> 200, Content-Type: text/markdown, Vary: Accept,
//                            nonempty Markdown body
//   Accept: text/html     -> unchanged HTML, Vary: Accept added
//   unknown path + md     -> 404, text/markdown body (>=20 chars) linking to
//                            /llms.txt and /sitemap.xml

export const MARKDOWN_TYPE = 'text/markdown; charset=utf-8';

// Parse an Accept header into [{ type, q }] per RFC 9110 section 12.5.1.
export function parseAccept(header) {
  if (!header) return [];
  return header.split(',').map((part) => {
    const [range, ...params] = part.trim().split(';');
    let q = 1;
    for (const p of params) {
      const [k, v] = p.trim().split('=');
      if (k && k.toLowerCase() === 'q') {
        const n = Number.parseFloat(v);
        q = Number.isFinite(n) ? n : 0;
      }
    }
    return { type: range.trim().toLowerCase(), q };
  }).filter((r) => r.type);
}

// Markdown wins only when the client names text/markdown explicitly with q>0
// and ranks it at least as high as an explicit text/html. Wildcards never
// select Markdown, so browsers (which never send text/markdown) keep HTML.
export function prefersMarkdown(header) {
  const ranges = parseAccept(header);
  const md = ranges.find((r) => r.type === 'text/markdown');
  if (!md || md.q <= 0) return false;
  const html = ranges.find((r) => r.type === 'text/html');
  return !html || md.q >= html.q;
}

// /            -> /index.md
// /about/      -> /about/index.md
// /about       -> /about/index.md
// /page.html   -> /page.md
// /llms.txt    -> null (already a text asset; never shadow it)
export function markdownPathFor(pathname) {
  if (pathname.endsWith('/')) return `${pathname}index.md`;
  const last = pathname.slice(pathname.lastIndexOf('/') + 1);
  if (last.endsWith('.html')) return `${pathname.slice(0, -5)}.md`;
  if (last.includes('.')) return null;
  return `${pathname}/index.md`;
}

export function appendVary(headers, value) {
  const existing = headers.get('Vary');
  if (!existing) {
    headers.set('Vary', value);
    return headers;
  }
  const parts = existing.split(',').map((s) => s.trim().toLowerCase());
  if (!parts.includes(value.toLowerCase()) && !parts.includes('*')) {
    headers.set('Vary', `${existing}, ${value}`);
  }
  return headers;
}

export function notFoundMarkdown({ siteName, origin, pathname }) {
  return [
    '# 404: Page not found',
    '',
    `There is no page at \`${pathname}\` on ${siteName}. It may have moved or never existed.`,
    '',
    '## Where to go next',
    '',
    `- [${siteName} home](${origin}/)`,
    `- [Site guide for AI agents (llms.txt)](${origin}/llms.txt)`,
    `- [XML sitemap](${origin}/sitemap.xml)`,
    '',
  ].join('\n');
}

function isHtml(response) {
  return (response.headers.get('Content-Type') || '').toLowerCase().includes('text/html');
}

function markdownResponse(body, status, method) {
  const headers = new Headers({
    'Content-Type': MARKDOWN_TYPE,
    Vary: 'Accept',
    'Cache-Control': 'public, max-age=300',
    'X-Content-Type-Options': 'nosniff',
  });
  return new Response(method === 'HEAD' ? null : body, { status, headers });
}

function withVaryAccept(response) {
  const headers = new Headers(response.headers);
  appendVary(headers, 'Accept');
  return new Response(response.body, {
    status: response.status,
    statusText: response.statusText,
    headers,
  });
}

// request:     the incoming Request
// next:        () => Promise<Response>, the Pages static/HTML pipeline
// fetchAsset:  (url) => Promise<Response>, normally env.ASSETS.fetch
// options:     { siteName, isKnownRoute? }
//   isKnownRoute(pathname) -> boolean is for SPA sites whose asset layer
//   answers every path with index.html. When given, unknown paths get a real
//   404 status for BOTH representations; the HTML 404 keeps the app shell so
//   the client router still renders its NotFound view.
export async function handleAgentRequest(request, next, fetchAsset, options) {
  const { siteName, isKnownRoute } = options;
  const url = new URL(request.url);
  const method = request.method.toUpperCase();
  if (method !== 'GET' && method !== 'HEAD') return next();

  const known = isKnownRoute ? isKnownRoute(url.pathname) : true;
  const wantsMarkdown = prefersMarkdown(request.headers.get('Accept'));

  if (wantsMarkdown) {
    const mdPath = known ? markdownPathFor(url.pathname) : null;
    if (mdPath) {
      const asset = await fetchAsset(new URL(mdPath, url.origin));
      // Guard: SPA asset layers answer a missing file with index.html + 200.
      if (asset.ok && !isHtml(asset)) {
        return markdownResponse(await asset.text(), 200, method);
      }
    }
    const html = await next();
    if (html.status === 404 || !known) {
      return markdownResponse(
        notFoundMarkdown({ siteName, origin: url.origin, pathname: url.pathname }),
        404,
        method,
      );
    }
    // A real page with no Markdown twin (or a non-HTML asset): serve it as is.
    return isHtml(html) ? withVaryAccept(html) : html;
  }

  const response = await next();
  if (!isHtml(response)) return response;
  if (!known && response.status === 200) {
    const headers = appendVary(new Headers(response.headers), 'Accept');
    return new Response(response.body, { status: 404, headers });
  }
  return withVaryAccept(response);
}
