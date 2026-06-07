import 'reflect-metadata'
import { afterEach, beforeEach, describe, expect, it } from 'bun:test'
import { getModels, getProviders } from '@earendil-works/pi-ai'
import { like } from 'drizzle-orm'
import { loadTestEnvFiles } from '../common/tests/load-test-env'

await loadTestEnvFiles()

const { appConfigService } = await import('@/config/app-configure')
const { DB } = await import('@/common/database')
const { LlmProviders } = await import('@/common/db-schema')
const { AppI18nDefaultLocaleConfig } = await import('@/config/i18n')
const { createWebServer } = await import('@/core/web-server')
const { SetupBootstrapActivationCodeConfig, SetupCompletedConfig } = await import('./config')

const webServer = await createWebServer({ serveStaticAssets: false })
const providerPrefix = `srp_${Date.now().toString(36)}_${Math.random().toString(36).slice(2, 8)}`.toLowerCase()
const catalog = firstCatalogModel()

beforeEach(resetSetupRouteTestConfig)
afterEach(resetSetupRouteTestConfig)

async function resetSetupRouteTestConfig() {
  await appConfigService.delete(SetupCompletedConfig)
  await appConfigService.delete(SetupBootstrapActivationCodeConfig)
  await appConfigService.delete(AppI18nDefaultLocaleConfig)
  await DB.delete(LlmProviders).where(like(LlmProviders.providerId, `${providerPrefix}%`))
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

describe('setup llm provider routes', () => {
  it('saves, checks, and lists LLM providers inside setup session scope', async () => {
    const cookie = await openSetupSession()
    const providerId = llmProviderId('main')

    const saved = await setupFetch('/api/setup/llm-providers', cookie, {
      method: 'PUT',
      body: {
        providers: [
          {
            providerId,
            piProvider: catalog.provider,
            apiKey: 'sk-setup',
            providerOptions: {
              maxRetries: 1
            }
          }
        ]
      }
    })

    expect(saved.status).toBe(200)
    await expect(saved.json()).resolves.toMatchObject({
      providers: [
        {
          providerId,
          apiKey: {
            present: true
          }
        }
      ]
    })

    const listed = await setupFetch('/api/setup/llm-providers', cookie)
    expect(listed.status).toBe(200)
    expect(((await listed.json()) as { providers: Array<{ providerId: string }> }).providers.some(provider => provider.providerId === providerId))
      .toBe(true)

    const models = await setupFetch(`/api/setup/llm-providers/${providerId}/models`, cookie)
    expect(models.status).toBe(200)
    expect(((await models.json()) as { models: Array<{ id: string }> }).models.some(model => model.id === catalog.model.id))
      .toBe(true)

    const checked = await setupFetch('/api/setup/llm-providers/check', cookie, {
      method: 'POST',
      body: {
        providerId,
        model: catalog.model.id
      }
    })
    expect(checked.status).toBe(200)
    await expect(checked.json()).resolves.toMatchObject({ ok: true })
  })

  it('returns 422 when setup check has no DB key even if the process env has one', async () => {
    const original = Bun.env.OPENAI_API_KEY
    Bun.env.OPENAI_API_KEY = 'sk-env-ignored'
    try {
      const cookie = await openSetupSession()
      const providerId = llmProviderId('missing_key')
      await setupFetch('/api/setup/llm-providers', cookie, {
        method: 'PUT',
        body: {
          providers: [
            {
              providerId,
              piProvider: catalog.provider
            }
          ]
        }
      })

      const checked = await setupFetch('/api/setup/llm-providers/check', cookie, {
        method: 'POST',
        body: {
          providerId,
          model: catalog.model.id
        }
      })
      expect(checked.status).toBe(422)
    } finally {
      if (original === undefined) delete Bun.env.OPENAI_API_KEY
      else Bun.env.OPENAI_API_KEY = original
    }
  })
})

async function openSetupSession(): Promise<string> {
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
        activationCode: 'ABCD1234'
      })
    })
  )
  expect(response.status).toBe(200)
  return response.headers.get('set-cookie') ?? ''
}

async function setupFetch(
  path: string,
  cookie: string,
  init: { method?: string; body?: unknown } = {}
): Promise<Response> {
  return webServer.handle(
    new Request(`http://localhost${path}`, {
      method: init.method ?? 'GET',
      headers: {
        Origin: 'http://localhost',
        'Content-Type': 'application/json',
        Cookie: cookie
      },
      body: init.body === undefined ? undefined : JSON.stringify(init.body)
    })
  )
}

function llmProviderId(name: string): string {
  return `${providerPrefix}_${name}`
}

function firstCatalogModel() {
  for (const provider of getProviders()) {
    const [model] = getModels(provider as never)
    if (model) return { provider, model }
  }
  throw new Error('Pi catalog did not expose any models')
}
