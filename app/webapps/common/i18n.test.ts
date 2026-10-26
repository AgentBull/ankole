import { expect, test } from 'bun:test'
import { get } from '@agentbull/active-support'
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

test('activity labels, shared errors, and private extension labels resolve from the built catalogs', async () => {
  await Promise.all([loadLocale('ja-JP'), loadLocale('en-US')])
  const dynamicActivityKey = ['conversations', 'delivery', 'reply', 'activity', 'computer_busy'].join('.')
  for (const key of [dynamicActivityKey, 'common.request_failed', 'pod.errors.field_conflict']) {
    expect(i18n.t(key, { lng: 'ja-JP' })).toBe(get(japanese, key))
  }
  if (edition === 'saas') {
    expect(get(english, 'saas.account.switch')).toBeString()
    expect(i18n.t('saas.account.switch', { lng: 'ja-JP' })).toBe(get(english, 'saas.account.switch'))
  }
})

test('locale loads share one promise and an unknown locale uses the English catalog', async () => {
  const first = loadLocale('ko-KR')
  expect(loadLocale('ko-KR')).toBe(first)
  await first
  expect(loadLocale('unknown-locale')).toBe(loadLocale('en-US'))
})
