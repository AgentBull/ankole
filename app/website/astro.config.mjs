// @ts-check

import { fileURLToPath } from 'node:url'
import mdx from '@astrojs/mdx'
import react from '@astrojs/react'
import sitemap from '@astrojs/sitemap'
import tailwindcss from '@tailwindcss/vite'
import { defineConfig } from 'astro/config'

// https://astro.build/config
export default defineConfig({
  site: 'https://ankole.agentbull.com',
  prefetch: true,
  i18n: {
    defaultLocale: 'en-US',
    locales: ['en-US', 'zh-Hans-CN', 'ja-JP', 'ko-KR'],
    routing: {
      prefixDefaultLocale: true,
      redirectToDefaultLocale: false
    }
  },
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
