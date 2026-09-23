// Markdown content negotiation + agent-friendly 404s for every route.
// Logic and tests live in seo-foundation/lib/agent-readiness/ (see
// ~/.claude/skills/site-qa/agent-readiness.md). The Markdown twins are
// written by the postbuild mirror step (package.json `postbuild`).
import { handleAgentRequest } from '../seo-foundation/lib/agent-readiness/negotiate.mjs';

export const onRequest = (ctx) =>
  handleAgentRequest(ctx.request, ctx.next, (url) => ctx.env.ASSETS.fetch(url), {
    siteName: 'health4.ai',
  });
