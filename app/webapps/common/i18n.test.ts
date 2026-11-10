import { expect, test } from 'bun:test'
import english from '@ankole/locales/en-US.json'
import chinese from '@ankole/locales/zh-Hans-CN.json'
import japanese from '@ankole/locales/ja-JP.json'
import korean from '@ankole/locales/ko-KR.json'
import i18n, { ensureAppletLocales, loadLocale } from './i18n'

const catalogs = [
  { locale: 'en-US', catalog: english },
  { locale: 'zh-Hans-CN', catalog: chinese },
  { locale: 'ja-JP', catalog: japanese },
  { locale: 'ko-KR', catalog: korean }
]

test('loads the built app and extension namespaces for every supported locale', async () => {
  for (const { locale, catalog } of catalogs) {
    await loadLocale(locale)
    expect(Object.keys(i18n.getResourceBundle(locale, 'translation')).sort()).toEqual(
      Object.keys(catalog)
        .filter(key => key !== '__meta__')
        .sort()
    )
  }
})

test('a missing translation uses the English catalog', async () => {
  await loadLocale('ja-JP')
  i18n.addResource('en-US', 'fallback-test', 'label', 'English fallback')
  try {
    expect(i18n.t('label', { lng: 'ja-JP', ns: 'fallback-test' })).toBe('English fallback')
  } finally {
    i18n.removeResourceBundle('en-US', 'fallback-test')
  }
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

test('same-origin Applet frames reuse resident catalogs synchronously without re-fetching JSON', async () => {
  await Promise.all([loadLocale('en-US'), loadLocale('zh-Hans-CN')])
  const previousWindow = Object.getOwnPropertyDescriptor(globalThis, 'window')
  const previousDocument = Object.getOwnPropertyDescriptor(globalThis, 'document')
  const previousLanguage = i18n.language
  const parentCatalogs = new Map([
    ['en-US', i18n.getResourceBundle('en-US', 'translation') as Record<string, unknown>],
    ['zh-Hans-CN', i18n.getResourceBundle('zh-Hans-CN', 'translation') as Record<string, unknown>]
  ])
  const hostWindow = { __ANKOLE_I18N_CATALOGS__: parentCatalogs }
  const frameWindow = { parent: hostWindow }
  Object.defineProperty(globalThis, 'window', { configurable: true, value: frameWindow })
  Object.defineProperty(globalThis, 'document', {
    configurable: true,
    value: { documentElement: { lang: 'zh-Hans-CN' } }
  })
  try {
    expect(ensureAppletLocales()).toBeUndefined()
    expect(i18n.language).toBe('zh-Hans-CN')
  } finally {
    await i18n.changeLanguage(previousLanguage)
    if (previousWindow) Object.defineProperty(globalThis, 'window', previousWindow)
    else Reflect.deleteProperty(globalThis, 'window')
    if (previousDocument) Object.defineProperty(globalThis, 'document', previousDocument)
    else Reflect.deleteProperty(globalThis, 'document')
  }
})
