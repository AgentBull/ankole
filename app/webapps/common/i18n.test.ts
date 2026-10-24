import { expect, test } from 'bun:test'
import { get } from '@agentbull/active-support'
import path from 'node:path'
import fullEnglish from '@ankole/locales/en-US.json'
import podEnglish from '@ankole/locales/en-US.json?pod'
import fullChinese from '@ankole/locales/zh-Hans-CN.json'
import podChinese from '@ankole/locales/zh-Hans-CN.json?pod'
import fullJapanese from '@ankole/locales/ja-JP.json'
import podJapanese from '@ankole/locales/ja-JP.json?pod'
import fullKorean from '@ankole/locales/ko-KR.json'
import podKorean from '@ankole/locales/ko-KR.json?pod'
import i18n, { loadLocale } from './i18n'
import { edition, localeDirectory } from '../scripts/edition'
import { podLocaleCatalogPlugin } from '../scripts/pod-locale-catalog'
import { createServer } from 'vite'

const catalogs = [
  { locale: 'en-US', full: fullEnglish, pod: podEnglish },
  { locale: 'zh-Hans-CN', full: fullChinese, pod: podChinese },
  { locale: 'ja-JP', full: fullJapanese, pod: podJapanese },
  { locale: 'ko-KR', full: fullKorean, pod: podKorean }
]

for (const { locale, full, pod } of catalogs) {
  test(`${edition} ${locale} keeps complete Pod/shared namespaces and leaves the ordinary catalog intact`, async () => {
    expect(full).toEqual(await Bun.file(path.join(localeDirectory, `${locale}.json`)).json())
    for (const namespace of ['common', 'pod', 'conversations', 'auth', 'setup']) {
      expect(pod[namespace]).toEqual(full[namespace])
      expect(pod[namespace]).toBeDefined()
    }
    for (const namespace of ['console', 'app_configure', 'plugins']) {
      expect(full[namespace]).toBeDefined()
      expect(pod[namespace]).toBeUndefined()
    }
    expect(pod.saas).toEqual(full.saas)
    const expected = ['__meta__', 'auth', 'setup', 'common', 'conversations', 'pod', ...(full.saas ? ['saas'] : [])]
    expect(Object.keys(pod).sort()).toEqual(expected.sort())
  })
}

test('the scoped catalog resolves dynamic activity, shared errors, and the SaaS account fallback', async () => {
  await Promise.all([loadLocale('ja-JP', 'pod'), loadLocale('en-US', 'pod')])
  const dynamicActivityKey = ['conversations', 'delivery', 'reply', 'activity', 'computer_busy'].join('.')
  for (const key of [dynamicActivityKey, 'common.request_failed', 'pod.errors.field_conflict']) {
    expect(i18n.t(key, { lng: 'ja-JP' })).toBe(get(podJapanese, key))
  }
  if (edition === 'saas') {
    expect(get(podEnglish, 'saas.account.switch')).toBeString()
    expect(i18n.t('saas.account.switch', { lng: 'ja-JP' })).toBe(get(podEnglish, 'saas.account.switch'))
  }
})

test('the existing locale cache can load the full catalog after a Pod view without losing either resource', async () => {
  const first = loadLocale('ko-KR', 'pod')
  expect(loadLocale('ko-KR', 'pod')).toBe(first)
  await first
  expect(i18n.getResource('ko-KR', 'translation', 'console')).toBeUndefined()
  await loadLocale('ko-KR')
  expect(i18n.getResource('ko-KR', 'translation', 'console')).toEqual(fullKorean.console)
  expect(i18n.getResource('ko-KR', 'translation', 'pod')).toEqual(podKorean.pod)
  expect(loadLocale('unknown-locale', 'pod')).toBe(loadLocale('en-US', 'pod'))
})

test('Vite converts the scoped JSON view and full catalog to executable modules through its native JSON plugin', async () => {
  const server = await createServer({
    configFile: false,
    root: localeDirectory,
    plugins: [podLocaleCatalogPlugin(localeDirectory)],
    server: { middlewareMode: true, watch: null, hmr: false },
    optimizeDeps: { noDiscovery: true },
    logLevel: 'silent'
  })
  try {
    for (const [query, expected] of [
      ['?pod', podEnglish],
      ['', fullEnglish]
    ] as const) {
      const result = await server.transformRequest(`/en-US.json${query}`)
      expect(result).not.toBeNull()
      const module = await import(`data:text/javascript;base64,${Buffer.from(result!.code).toString('base64')}`)
      expect(module.default).toEqual(expected)
    }
  } finally {
    await server.close()
  }
})
