import IntlMessageFormat from 'intl-messageformat'
import type { Locale } from './config'
import { BCP47, DEFAULT_LOCALE } from './config'
import en from './locales/en.json'
import ja from './locales/ja.json'
import ko from './locales/ko.json'
import zh from './locales/zh.json'

const messages: Record<Locale, Record<string, string>> = {
  'en-US': en,
  'zh-Hans-CN': zh,
  'ja-JP': ja,
  'ko-KR': ko
}

const cache = new Map<string, IntlMessageFormat>()

export function t(locale: Locale, key: string, values?: Record<string, unknown>): string {
  const msg = messages[locale]?.[key] ?? messages[DEFAULT_LOCALE][key] ?? key
  const cacheKey = `${locale}:${key}`

  let fmt = cache.get(cacheKey)
  if (!fmt) {
    fmt = new IntlMessageFormat(msg, BCP47[locale])
    cache.set(cacheKey, fmt)
  }

  return fmt.format(values) as string
}

/** Builds a localized absolute path: /{lang}/rest/of/path, honoring the deployed base URL. */
export function localePath(locale: Locale, path: string = ''): string {
  const base = import.meta.env.BASE_URL.replace(/\/+$/, '')
  const clean = path.replace(/^\/+|\/+$/g, '')
  return `${base}/${locale}${clean ? `/${clean}` : ''}/`
}
