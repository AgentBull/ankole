import { expect, test } from 'bun:test'
import path from 'node:path'
import english from '@ankole/locales/en-US.json'
import chinese from '@ankole/locales/zh-Hans-CN.json'
import japanese from '@ankole/locales/ja-JP.json'
import korean from '@ankole/locales/ko-KR.json'
import i18n, { loadLocale } from './i18n'
import { edition, localeDirectory } from '../scripts/edition'

const catalogs = [
  { locale: 'en-US', catalog: english },
  { locale: 'zh-Hans-CN', catalog: chinese },
  { locale: 'ja-JP', catalog: japanese },
  { locale: 'ko-KR', catalog: korean }
]

for (const { locale, catalog } of catalogs) {
  test(`${edition} ${locale} makes every built namespace available to app and extension components`, async () => {
    expect(catalog).toEqual(await Bun.file(path.join(localeDirectory, `${locale}.json`)).json())
    await loadLocale(locale)
    expect(Object.keys(i18n.getResourceBundle(locale, 'translation')).sort()).toEqual(
      Object.keys(catalog)
        .filter(key => key !== '__meta__')
        .sort()
    )
  })
}

test('a missing translation uses the English catalog', async () => {
  await loadLocale('ja-JP')
  i18n.addResource('en-US', 'fallback-test', 'label', 'English fallback')
  try {
    expect(i18n.t('label', { lng: 'ja-JP', ns: 'fallback-test' })).toBe('English fallback')
  } finally {
    i18n.removeResourceBundle('en-US', 'fallback-test')
  }
})

test('locale loads share one promise and an unknown locale uses the English catalog', async () => {
  const first = loadLocale('ko-KR')
  expect(loadLocale('ko-KR')).toBe(first)
  await first
  expect(loadLocale('unknown-locale')).toBe(loadLocale('en-US'))
})

test('a locale change updates the document language', async () => {
  const previous = Object.getOwnPropertyDescriptor(globalThis, 'document')
  const previousLanguage = i18n.language
  const document = { documentElement: { lang: 'en-US' } }
  Object.defineProperty(globalThis, 'document', { configurable: true, value: document })
  try {
    await loadLocale('ja-JP')
    await i18n.changeLanguage('ja-JP')
    expect(document.documentElement.lang).toBe('ja-JP')
  } finally {
    await i18n.changeLanguage(previousLanguage)
    if (previous) Object.defineProperty(globalThis, 'document', previous)
    else Reflect.deleteProperty(globalThis, 'document')
  }
})
