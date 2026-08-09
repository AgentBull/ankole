export const LOCALES = ['en-US', 'zh-Hans-CN', 'ja-JP', 'ko-KR'] as const
export type Locale = (typeof LOCALES)[number]

export const DEFAULT_LOCALE: Locale = 'en-US'

/** BCP 47 tags for the html lang attribute and hreflang links. */
export const BCP47: Record<Locale, string> = {
  'en-US': 'en-US',
  'zh-Hans-CN': 'zh-Hans-CN',
  'ja-JP': 'ja-JP',
  'ko-KR': 'ko-KR'
}

/** Locale labels for the language switcher. */
export const LOCALE_LABELS: Record<Locale, string> = {
  'en-US': 'English',
  'zh-Hans-CN': '中文',
  'ja-JP': '日本語',
  'ko-KR': '한국어'
}

export function isValidLocale(value: string): value is Locale {
  return LOCALES.includes(value as Locale)
}
