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
  },
});
