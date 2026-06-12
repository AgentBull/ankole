import { readFileSync } from 'node:fs'
import path from 'node:path'
import { AppEnv } from '@/config/env'
import { DEFAULT_LOCALE } from '@/config/i18n-locales'

export type SpaName = 'setup' | 'sessions' | 'console' | 'reasoning-trace'

export type DevSpaHtmlRenderer = (app: SpaName, request: Request) => Promise<Response>

interface SpaHtmlOptions {
  app: SpaName
  title: string
  locale?: string
  request?: Request
  devRenderer?: DevSpaHtmlRenderer
}

interface AssetManifestEntry {
  js: string
  css?: string
}

const defaultAssets: Record<SpaName, AssetManifestEntry> = {
  setup: { js: '/assets/setup-entry.js', css: '/assets/setup-entry.css' },
  sessions: { js: '/assets/sessions-entry.js', css: '/assets/sessions-entry.css' },
  console: { js: '/assets/console-entry.js', css: '/assets/console-entry.css' },
  'reasoning-trace': { js: '/assets/reasoning-trace-entry.js', css: '/assets/reasoning-trace-entry.css' }
}

let cachedManifest: Partial<Record<SpaName, AssetManifestEntry>> | undefined

export async function renderSpaHtml(options: SpaHtmlOptions): Promise<Response> {
  const devHtml = await renderDevSpaHtml(options)
  if (devHtml) return devHtml

  const assets = assetManifest()[options.app] ?? defaultAssets[options.app]
  const locale = escapeHtmlAttribute(options.locale ?? DEFAULT_LOCALE)
  const title = escapeHtml(options.title)
  const css = assets.css ? `<link rel="stylesheet" href="${escapeHtmlAttribute(assets.css)}">` : ''
  const html = `<!doctype html>
<html lang="${locale}">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>${title}</title>
  ${css}
</head>
<body>
  <div id="root"></div>
  <script type="module" src="${escapeHtmlAttribute(assets.js)}"></script>
</body>
</html>`

  return new Response(html, {
    headers: {
      'content-type': 'text/html; charset=utf-8'
    }
  })
}

async function renderDevSpaHtml(options: SpaHtmlOptions): Promise<Response | undefined> {
  if (!AppEnv.IS_DEVELOPMENT || !options.devRenderer || !options.request) return

  const response = await options.devRenderer(options.app, options.request)
  if (!response.ok) {
    throw new Error(`Failed to render ${options.app} SPA through Bun dev server: ${response.status}`)
  }

  const html = (await response.text())
    .replaceAll('__BULLX_LOCALE__', escapeHtmlAttribute(options.locale ?? DEFAULT_LOCALE))
    .replaceAll('__BULLX_TITLE__', escapeHtml(options.title))

  return new Response(html, {
    headers: {
      'content-type': 'text/html; charset=utf-8'
    }
  })
}

function assetManifest(): Partial<Record<SpaName, AssetManifestEntry>> {
  if (cachedManifest && !AppEnv.IS_DEVELOPMENT) return cachedManifest

  const manifestPath = path.resolve(import.meta.dir, '../../public/assets/manifest.json')
  try {
    const manifest = JSON.parse(readFileSync(manifestPath, 'utf8')) as Partial<Record<SpaName, AssetManifestEntry>>
    if (!AppEnv.IS_DEVELOPMENT) cachedManifest = manifest

    return manifest
  } catch {
    if (!AppEnv.IS_DEVELOPMENT) cachedManifest = defaultAssets

    return defaultAssets
  }
}

function escapeHtml(value: string): string {
  return value
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;')
}

function escapeHtmlAttribute(value: string): string {
  return escapeHtml(value)
}
