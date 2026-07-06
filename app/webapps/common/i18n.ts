import i18n, { type Resource } from 'i18next'
import MF2 from 'i18next-mf2'
import { initReactI18next } from 'react-i18next'
import enUS from '../../locales/en-US.toml'
import zhHansCN from '../../locales/zh-Hans-CN.toml'

const catalogs = {
  'en-US': enUS,
  'zh-Hans-CN': zhHansCN
} as const

const resources = Object.fromEntries(
  Object.entries(catalogs).map(([locale, catalog]) => [locale, { translation: clientCatalog(catalog) }])
) as Resource

const supportedLngs = Object.keys(catalogs)

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
    // The Phoenix shell writes the server-selected locale to `<html lang>`, so
    // the SPA starts with the same locale before it fetches any user state.
    lng: activeLocale(),
    ns: ['translation'],
    react: { useSuspense: false },
    resources,
    supportedLngs
  })

export default i18n

/** Returns a short native-language label for locale pickers. */
export function nativeLocaleLabel(locale: string): string {
  if (!supportedLngs.includes(locale)) return locale

  const fixedT = i18n.getFixedT(locale)
  const label = fixedT('locale.native_label')

  return label === 'locale.native_label' ? locale : label
}

function activeLocale() {
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
