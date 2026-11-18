// @ts-check

import { fileURLToPath } from 'node:url'
import mdx from '@astrojs/mdx'
import react from '@astrojs/react'
import sitemap from '@astrojs/sitemap'
import tailwindcss from '@tailwindcss/vite'
import { defineConfig } from 'astro/config'

// The site was published in these locales before it became English only. A static build rejects
// a splat redirect, because the destination must be an existing route. Locale roots redirect
// here. Any deeper retired path is handled by src/pages/404.astro.
const RETIRED_LOCALES = ['zh-Hans-CN', 'ja-JP', 'ko-KR']

// https://astro.build/config
export default defineConfig({
  site: 'https://ankole.agentbull.com',
  prefetch: true,
  i18n: {
    defaultLocale: 'en-US',
    locales: ['en-US'],
    routing: {
      prefixDefaultLocale: true,
      redirectToDefaultLocale: false
    }
  },
  redirects: Object.fromEntries(RETIRED_LOCALES.map(locale => [`/${locale}`, '/en-US/'])),
  integrations: [mdx(), react(), sitemap()],
  vite: {
    resolve: {
      alias: {
        '@': fileURLToPath(new URL('./src', import.meta.url))
      }
    },
    // The isolated install links @tailwindcss/vite against its own vite copy,
    // so its Plugin type does not unify with the vite type Astro compiles against.
    plugins: [/** @type {any} */ (tailwindcss())]
  }
})
