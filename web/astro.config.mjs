import { defineConfig } from 'astro/config';
import sitemap from '@astrojs/sitemap';
import tailwindcss from '@tailwindcss/vite';

export default defineConfig({
  site: 'https://health4.ai',
  // Cloudflare serves /x as a 308 to /x/; links and canonicals must use the slashed form or Search Console reports "Page with redirect".
  trailingSlash: 'always',
  integrations: [sitemap()],
  vite: {
    plugins: [tailwindcss()],
    // Keep the consent module a separate file. Without this, Astro inlines it into pages once it
    // is under 4 KiB (as it is without the Meta Pixel loader), and consent-dist.test.mjs could no
    // longer tell the gated loader from an ungated inline tracker start.
    build: { assetsInlineLimit: 0 },
  },
});
