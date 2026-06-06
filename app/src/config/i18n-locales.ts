export const DEFAULT_LOCALE = 'en-US'

export const SUPPORTED_LOCALES = ['en-US', 'zh-Hans-CN'] as const

export type SupportedLocale = (typeof SUPPORTED_LOCALES)[number]

const SUPPORTED_LOCALE_NATIVE_LABELS: Record<SupportedLocale, string> = {
  'en-US': 'English',
  'zh-Hans-CN': '简体中文'
}

export function isSupportedLocale(locale: string): locale is SupportedLocale {
  return (SUPPORTED_LOCALES as readonly string[]).includes(locale)
}

export function normalizeLocale(locale: string | null | undefined): SupportedLocale {
  return locale && isSupportedLocale(locale) ? locale : DEFAULT_LOCALE
}

export function nativeLocaleLabel(locale: string): string {
  return isSupportedLocale(locale) ? SUPPORTED_LOCALE_NATIVE_LABELS[locale] : locale
}
