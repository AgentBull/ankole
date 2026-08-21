import i18n from 'i18next'
import MF2 from 'i18next-mf2'
import { initReactI18next } from 'react-i18next'

// Each catalog loads through a dynamic import so a session only pays for the
// active locale plus the en-US fallback, not all four catalogs.
const catalogLoaders: Record<string, () => Promise<{ default: unknown }>> = {
  'en-US': () => import('../../locales/en-US.toml'),
  'ja-JP': () => import('../../locales/ja-JP.toml'),
  'ko-KR': () => import('../../locales/ko-KR.toml'),
  'zh-Hans-CN': () => import('../../locales/zh-Hans-CN.toml')
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
      const catalog = clientCatalog(module.default)
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
    })
    loadedLocales.set(supported, loading)
  }
  return loading
}

export default i18n

/** Returns the locale ids that the web applications can render. */
export function availableLocaleIDs(): string[] {
  return [...supportedLngs]
}

/** Returns a short native-language label for locale pickers. */
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

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}
