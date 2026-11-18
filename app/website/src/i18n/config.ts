export const LOCALES = ['en-US'] as const
export type Locale = (typeof LOCALES)[number]

export const DEFAULT_LOCALE: Locale = 'en-US'

/** BCP 47 tags for the html lang attribute and hreflang links. */
export const BCP47: Record<Locale, string> = {
  'en-US': 'en-US'
}

/** Locale labels for the llms.txt links to other locales. */
export const LOCALE_LABELS: Record<Locale, string> = {
  'en-US': 'English'
}

export function isValidLocale(value: string): value is Locale {
  return LOCALES.includes(value as Locale)
}
