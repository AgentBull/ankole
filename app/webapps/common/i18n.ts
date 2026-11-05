import { isRecord } from '@agentbull/active-support'
import i18n from 'i18next'
import MF2 from 'i18next-mf2'
import { initReactI18next } from 'react-i18next'

const catalogLoaders: Record<string, () => Promise<{ default: unknown }>> = {
  'en-US': () => import('@ankole/locales/en-US.json'),
  'ja-JP': () => import('@ankole/locales/ja-JP.json'),
  'ko-KR': () => import('@ankole/locales/ko-KR.json'),
  'zh-Hans-CN': () => import('@ankole/locales/zh-Hans-CN.json')
}

// Native labels are locale-invariant constants of the locale itself, so a
// picker can name every choice without loading the other catalogs.
const nativeLocaleLabels: Record<string, string> = {
  'en-US': 'English',
  'ja-JP': '日本語',
  'ko-KR': '한국어',
  'zh-Hans-CN': '简体中文'
}

const supportedLngs = Object.keys(catalogLoaders)
const loadedLocales = new Map<string, Promise<void>>()
const loadedCatalogs = new Map<string, Record<string, unknown>>()

type CatalogHostWindow = Window & {
  __ANKOLE_I18N_CATALOGS__?: ReadonlyMap<string, Record<string, unknown>>
}

if (typeof window !== 'undefined') {
  ;(window as CatalogHostWindow).__ANKOLE_I18N_CATALOGS__ = loadedCatalogs
}

i18n.on('languageChanged', locale => {
  if (typeof document !== 'undefined' && document.documentElement && locale) {
    document.documentElement.lang = locale
  }
})

function applyCatalog(supported: string, catalog: Record<string, unknown>): void {
  loadedCatalogs.set(supported, catalog)
  if (i18n.isInitialized) {
    i18n.addResourceBundle(supported, 'translation', catalog)
    return
  }
  i18n
    .use(MF2)
    .use(initReactI18next)
    .init({
      fallbackLng: 'en-US',
      i18nFormat: {
        parseErrorHandler: (_err: Error, _key: string, source: string) => source
      },
      initAsync: false,
      interpolation: { escapeValue: false },
      load: 'currentOnly',
      lng: activeLocale(),
      ns: ['translation'],
      react: { useSuspense: false },
      resources: { [supported]: { translation: catalog } },
      supportedLngs
    })
}

function parentCatalogMap(): ReadonlyMap<string, Record<string, unknown>> | undefined {
  if (typeof window === 'undefined') return undefined
  try {
    if (window.parent && window.parent !== window) {
      return (window.parent as CatalogHostWindow).__ANKOLE_I18N_CATALOGS__
    }
  } catch {
    // Cross-origin test harnesses fall back to loading catalogs directly.
  }
  return undefined
}

/**
 * Hydrates an Applet frame's i18next instance synchronously from the same-origin
 * Pod host window when its normalized catalogs are already resident in memory,
 * falling back to async catalog imports only in standalone frames.
 */
export function ensureAppletLocales(): Promise<void> | undefined {
  const required = [...new Set([activeLocale(), 'en-US'])].map(locale =>
    supportedLngs.includes(locale) ? locale : 'en-US'
  )
  const hostCatalogs = parentCatalogMap()
  if (hostCatalogs) {
    for (const supported of required) {
      if (loadedCatalogs.has(supported)) continue
      const catalog = hostCatalogs.get(supported)
      if (!catalog) continue
      applyCatalog(supported, catalog)
      loadedLocales.set(supported, Promise.resolve())
    }
  }
  const missing = required.filter(supported => !loadedCatalogs.has(supported))
  if (missing.length === 0) {
    const current = supportedLngs.includes(activeLocale()) ? activeLocale() : 'en-US'
    if (i18n.isInitialized && i18n.language !== current) void i18n.changeLanguage(current)
    return undefined
  }
  return Promise.all(missing.map(loadLocale)).then(() => undefined)
}

/**
 * Loads one catalog and makes it available to `t`. The first call also
 * initializes i18next synchronously with that catalog, so rendering after the
 * returned promise settles never shows untranslated keys. `mountApp` awaits
 * the active locale and the en-US fallback before the first render.
 */
export function loadLocale(locale: string): Promise<void> {
  const supported = supportedLngs.includes(locale) ? locale : 'en-US'
  let loading = loadedLocales.get(supported)
  if (!loading) {
    loading = catalogLoaders[supported]!().then(module => {
      applyCatalog(supported, clientCatalog(module.default))
    })
    loadedLocales.set(supported, loading)
  }
  return loading
}

export default i18n

export function availableLocaleIDs(): string[] {
  return [...supportedLngs]
}

export function nativeLocaleLabel(locale: string): string {
  return nativeLocaleLabels[locale] ?? locale
}

/**
 * The Phoenix shell writes the server-selected locale to `<html lang>`, so
 * the SPA starts with the same locale before it fetches any user state.
 */
export function activeLocale(): string {
  if (typeof document === 'undefined') return 'en-US'
  return document.documentElement.lang || 'en-US'
}

function clientCatalog(catalog: unknown): Record<string, unknown> {
  if (!isRecord(catalog)) throw new Error('i18n catalog must be a TOML table')

  return Object.fromEntries(
    Object.entries(catalog)
      .filter(([key]) => key !== '__meta__')
      .map(([key, value]) => [key, normalizeCatalogNode(value, [key])])
  )
}

function normalizeCatalogNode(node: unknown, path: string[]): unknown {
  if (typeof node === 'string') return node

  if (!isRecord(node)) {
    throw new Error(`i18n catalog key ${path.join('.')} must be a string or table`)
  }

  if (node.__mf2__ === true) {
    const allowedRichLeafKeys = new Set(['__mf2__', 'message', 'description', 'placeholders'])
    const unknownKey = Object.keys(node).find(key => !allowedRichLeafKeys.has(key))

    if (unknownKey) {
      throw new Error(`i18n rich catalog key ${path.join('.')} has unknown field ${unknownKey}`)
    }

    if (typeof node.message !== 'string') {
      throw new Error(`i18n rich catalog key ${path.join('.')} must include a string message`)
    }

    return node.message
  }

  return Object.fromEntries(
    Object.entries(node).map(([key, value]) => [key, normalizeCatalogNode(value, [...path, key])])
  )
}
