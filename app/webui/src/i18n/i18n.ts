import enUS from '@locales/en-US.toml'
import zhHansCN from '@locales/zh-Hans-CN.toml'
import i18n from 'i18next'
import { initReactI18next } from 'react-i18next'
import { DEFAULT_LOCALE, SUPPORTED_LOCALES, isSupportedLocale, normalizeLocale } from '@/config/i18n-locales'
import { Mf2PostProcessor, Mf2ReactPreset } from './mf2'

const resources = {
  'en-US': { translation: enUS },
  'zh-Hans-CN': { translation: zhHansCN }
}

i18n
  .use(Mf2PostProcessor)
  .use(Mf2ReactPreset)
  .use(initReactI18next)
  .init({
    lng: activeLocale(),
    fallbackLng: DEFAULT_LOCALE,
    supportedLngs: [...SUPPORTED_LOCALES],
    resources,
    defaultNS: 'translation',
    ns: ['translation'],
    postProcess: ['mf2'],
    load: 'currentOnly',
    initAsync: false,
    interpolation: { escapeValue: false },
    react: { useSuspense: false }
  })

i18n.on('languageChanged', syncDocumentLocale)
syncDocumentLocale(i18n.resolvedLanguage ?? i18n.language)

export default i18n

function activeLocale() {
  if (typeof document === 'undefined') return DEFAULT_LOCALE

  return normalizeLocale(document.documentElement.lang)
}

function syncDocumentLocale(locale: string | undefined) {
  if (typeof document === 'undefined' || !locale) return
  if (!isSupportedLocale(locale)) return

  document.documentElement.lang = locale
}
