import 'reflect-metadata'
import { afterEach, beforeEach, describe, expect, it } from 'bun:test'
import { loadTestEnvFiles } from '../common/tests/load-test-env'

await loadTestEnvFiles()

const { appConfigService } = await import('@/config/app-configure')
const { AppI18nDefaultLocaleConfig } = await import('@/config/i18n')
const { createWebServer } = await import('@/core/web-server')
const { SetupBootstrapActivationCodeConfig, SetupCompletedConfig } = await import('./config')

const webServer = await createWebServer({ serveStaticAssets: false })

beforeEach(resetSetupRouteTestConfig)
afterEach(resetSetupRouteTestConfig)

async function resetSetupRouteTestConfig() {
  await appConfigService.delete(SetupCompletedConfig)
  await appConfigService.delete(SetupBootstrapActivationCodeConfig)
  await appConfigService.delete(AppI18nDefaultLocaleConfig)
}

describe('setup routes i18n', () => {
  it('returns the configured setup locale and supported locale choices', async () => {
    await appConfigService.set(AppI18nDefaultLocaleConfig, 'zh-Hans-CN')

    const response = await webServer.handle(new Request('http://localhost/api/setup/state'))

    expect(response.status).toBe(200)
    await expect(response.json()).resolves.toMatchObject({
      completed: false,
      authenticated: false,
      currentLocale: 'zh-Hans-CN',
      availableLocales: ['en-US', 'zh-Hans-CN']
    })
  })

  it('persists the selected locale when opening a setup session', async () => {
    await appConfigService.set(SetupCompletedConfig, false)
    await appConfigService.set(SetupBootstrapActivationCodeConfig, 'ABCD1234')

    const response = await webServer.handle(
      new Request('http://localhost/api/setup/sessions', {
        method: 'POST',
        headers: {
          Origin: 'http://localhost',
          'Content-Type': 'application/json'
        },
        body: JSON.stringify({
          activationCode: 'ABCD1234',
          locale: 'zh-Hans-CN'
        })
      })
    )

    expect(response.status).toBe(200)
    await expect(response.json()).resolves.toEqual({ ok: true })
    expect(await appConfigService.get(AppI18nDefaultLocaleConfig)).toBe('zh-Hans-CN')
  })

  it('rejects unsupported locales before opening a setup session', async () => {
    await appConfigService.set(SetupCompletedConfig, false)
    await appConfigService.set(SetupBootstrapActivationCodeConfig, 'ABCD1234')
    await appConfigService.set(AppI18nDefaultLocaleConfig, 'zh-Hans-CN')

    const response = await webServer.handle(
      new Request('http://localhost/api/setup/sessions', {
        method: 'POST',
        headers: {
          Origin: 'http://localhost',
          'Content-Type': 'application/json'
        },
        body: JSON.stringify({
          activationCode: 'ABCD1234',
          locale: 'pirate'
        })
      })
    )

    expect(response.status).toBe(422)
    expect(response.headers.get('set-cookie')).toBeNull()
    await expect(response.json()).resolves.toEqual({ error: 'unsupported locale' })
    expect(await appConfigService.get(AppI18nDefaultLocaleConfig)).toBe('zh-Hans-CN')
  })

  it('uses the configured locale on the setup HTML shell', async () => {
    await appConfigService.set(AppI18nDefaultLocaleConfig, 'zh-Hans-CN')

    const response = await webServer.handle(new Request('http://localhost/setup'))
    const html = await response.text()

    expect(response.status).toBe(200)
    expect(html).toContain('<html lang="zh-Hans-CN">')
  })
})
