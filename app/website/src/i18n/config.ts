export const LOCALES = ['en-US', 'zh-Hans-CN'] as const
export type Locale = (typeof LOCALES)[number]

export const DEFAULT_LOCALE: Locale = 'en-US'

/** BCP 47 tags for the html lang attribute and hreflang links. */
export const BCP47: Record<Locale, string> = {
  'en-US': 'en-US',
  'zh-Hans-CN': 'zh-Hans-CN'
}

/** Locale labels for the language switcher. */
export const LOCALE_LABELS: Record<Locale, string> = {
  'en-US': 'English',
  'zh-Hans-CN': '中文'
}

export function isValidLocale(value: string): value is Locale {
  return LOCALES.includes(value as Locale)
}
