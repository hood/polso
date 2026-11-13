import starlight from '@astrojs/starlight';
import { defineConfig } from 'astro/config';

// Served from hood.github.io/polso. A custom domain later: set SITE to it and BASE to '/'.
const site = process.env.SITE ?? 'https://hood.github.io';
const base = process.env.BASE ?? '/polso';

export default defineConfig({
  site,
  base,
  integrations: [
    starlight({
      title: 'polso',
      description: 'Your MacBook notch as a live meter for anything.',
      logo: { src: './src/assets/logo.svg', replacesTitle: false },
      favicon: '/favicon.svg',
      social: [{ icon: 'github', label: 'GitHub', href: 'https://github.com/hood/polso' }],
      editLink: { baseUrl: 'https://github.com/hood/polso/edit/main/site/' },
      customCss: ['./src/styles/custom.css'],
      expressiveCode: { themes: ['github-dark-default', 'github-light-default'] },
      head: [
        { tag: 'meta', attrs: { property: 'og:image', content: `${site}${base}/og.png` } },
        { tag: 'meta', attrs: { name: 'twitter:card', content: 'summary_large_image' } },
      ],
      sidebar: [
        { label: 'Start', items: ['start/getting-started', 'start/how-it-works'] },
        { label: 'Feed it', items: ['send/socket', 'send/sources', 'send/recipes'] },
        { label: 'Customize', items: ['customize/configuration', 'customize/indicators'] },
        { label: 'Reference', items: ['reference/development', 'reference/troubleshooting'] },
      ],
    }),
  ],
});
