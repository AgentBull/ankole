import { isRecord } from '@agentbull/active-support'
import i18n from 'i18next'
import MF2 from 'i18next-mf2'
import { initReactI18next } from 'react-i18next'

export type LocaleScope = 'full' | 'pod'

// ?pod is a build view of the same generated catalog. Other entries keep the full catalog.
const catalogLoaders: Record<string, (scope: LocaleScope) => Promise<{ default: unknown }>> = {
  'en-US': scope => (scope === 'pod' ? import('@ankole/locales/en-US.json?pod') : import('@ankole/locales/en-US.json')),
  'ja-JP': scope => (scope === 'pod' ? import('@ankole/locales/ja-JP.json?pod') : import('@ankole/locales/ja-JP.json')),
  'ko-KR': scope => (scope === 'pod' ? import('@ankole/locales/ko-KR.json?pod') : import('@ankole/locales/ko-KR.json')),
  'zh-Hans-CN': scope =>
    scope === 'pod' ? import('@ankole/locales/zh-Hans-CN.json?pod') : import('@ankole/locales/zh-Hans-CN.json')
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
export function loadLocale(locale: string, scope: LocaleScope = 'full'): Promise<void> {
  const supported = supportedLngs.includes(locale) ? locale : 'en-US'
  const key = `${scope}:${supported}`
  let loading = loadedLocales.get(key)
  if (!loading) {
    loading = catalogLoaders[supported]!(scope).then(module => {
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
    loadedLocales.set(key, loading)
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
