import { afterEach, beforeEach, describe, expect, it } from 'bun:test'
import { getModels, getProviders } from '@/llm'
import path from 'node:path'
import { like } from 'drizzle-orm'
import { loadTestEnvFiles } from '@/common/tests/load-test-env'
import type { AppConfigDefinition, AppConfigJsonValue } from '@/config/app-configure'

await loadTestEnvFiles()

const { DB } = await import('@/common/database')
const { LlmProviders, PrincipalGroups, Principals } = await import('@/common/db-schema')
const { createWebServer } = await import('@/core/web-server')
const { ensureBuiltInAdminGroup } = await import('@/principals/authorization/groups')
const { insertMembership } = await import('@/principals/authorization/memberships')
const { createHuman } = await import('@/principals/human-users/service')
const { ADMIN_SESSION_COOKIE, cookieHeader, createAdminSessionCookie } = await import('@/principals/admin-auth/session')
const { appConfigService } = await import('@/config/app-configure')
const { AppI18nDefaultLocaleConfig } = await import('@/config/i18n')
const { SystemTimezoneConfig } = await import('@/config/system')
const { AdminAuthPublicBaseUrlConfig } = await import('@/principals/admin-auth/config')
const { WebExaApiKey, WebExtractProviderConfig, WebJinaApiKey, WebParallelApiKey, WebSearchProviderConfig } =
  await import('@/ai-agent/web/config')

const webServer = await createWebServer({ serveStaticAssets: false })
const testPrefix = `test_console_routes_${Date.now()}_${Math.random().toString(36).slice(2)}`.toLowerCase()
const providerPrefix = `crp_${Date.now().toString(36)}_${Math.random().toString(36).slice(2, 8)}`.toLowerCase()
const catalog = firstCatalogModel()
const pluginRoot = path.resolve(import.meta.dir, '../../../plugin')
const originalPluginDir = Bun.env.PLUGIN_DIR
let adminCookie = ''

beforeEach(async () => {
  Bun.env.PLUGIN_DIR = pluginRoot
  await clearTestRows()
  const adminUid = `${testPrefix}_admin`
  await createHuman({ uid: adminUid })
  const adminGroup = await ensureBuiltInAdminGroup()
  await insertMembership(adminUid, adminGroup.id)
  adminCookie = cookieHeader(
    ADMIN_SESSION_COOKIE,
    createAdminSessionCookie({
      principalUid: adminUid,
      providerId: 'test',
      externalId: 'test-admin'
    }),
    { secure: false }
  )
})

afterEach(async () => {
  await clearTestRows()
  if (originalPluginDir === undefined) delete Bun.env.PLUGIN_DIR
  else Bun.env.PLUGIN_DIR = originalPluginDir
})

describe('console routes error responses', () => {
  it('returns JSON for non-domain errors raised inside console routes', async () => {
    const response = await webServer.handle(
      new Request('http://localhost/api/console/agents', {
        method: 'POST',
        headers: {
          Origin: 'http://localhost',
          'Content-Type': 'application/json',
          Cookie: adminCookie
        },
        body: JSON.stringify({ uid: '' })
      })
    )

    expect(response.status).toBe(422)
    expect(response.headers.get('content-type')).toContain('application/json')
    await expect(response.json()).resolves.toMatchObject({
      error: {
        code: 422
      }
    })
  })
})

describe('console llm provider routes', () => {
  it('creates, checks, lists models, updates, and deletes providers', async () => {
    const providerId = llmProviderId('main')
    const created = await authedFetch('/api/console/llm-providers', {
      method: 'POST',
      body: {
        providerId,
        llmProvider: catalog.provider,
        apiKey: 'sk-route',
        providerOptions: {
          timeoutMs: 1000
        }
      }
    })

    expect(created.status).toBe(201)
    await expect(created.json()).resolves.toMatchObject({
      provider: {
        providerId,
        llmProvider: catalog.provider,
        apiKey: {
          present: true,
          masked: '********'
        }
      }
    })

    const listed = await authedFetch('/api/console/llm-providers')
    expect(listed.status).toBe(200)
    expect(
      ((await listed.json()) as { providers: Array<{ providerId: string }> }).providers.some(
        provider => provider.providerId === providerId
      )
    ).toBe(true)

    const checked = await authedFetch('/api/console/llm-providers/check', {
      method: 'POST',
      body: {
        providerId,
        model: catalog.model.id
      }
    })
    expect(checked.status).toBe(200)
    await expect(checked.json()).resolves.toMatchObject({
      ok: true,
      model: {
        id: catalog.model.id
      }
    })

    const models = await authedFetch(`/api/console/llm-providers/${providerId}/models`)
    expect(models.status).toBe(200)
    expect(
      ((await models.json()) as { models: Array<{ id: string }> }).models.some(model => model.id === catalog.model.id)
    ).toBe(true)

    const cleared = await authedFetch(`/api/console/llm-providers/${providerId}`, {
      method: 'PUT',
      body: {
        apiKey: null
      }
    })
    expect(cleared.status).toBe(200)
    await expect(cleared.json()).resolves.toMatchObject({
      provider: {
        apiKey: {
          present: false
        }
      }
    })

    const missingKey = await authedFetch('/api/console/llm-providers/check', {
      method: 'POST',
      body: {
        providerId,
        model: catalog.model.id
      }
    })
    expect(missingKey.status).toBe(422)

    const deleted = await authedFetch(`/api/console/llm-providers/${providerId}`, { method: 'DELETE' })
    expect(deleted.status).toBe(204)
  })
})

describe('console expanded resource routes', () => {
  it('exposes overview, human users, principal groups, and agent library resources', async () => {
    const agentUid = `${testPrefix}_agent`
    const humanUid = `${testPrefix}_operator`
    const groupName = `${testPrefix}_team`

    const createdAgent = await authedFetch('/api/console/agents', {
      method: 'POST',
      body: {
        uid: agentUid,
        displayName: 'Route Test Agent',
        mission: 'Start with route mission.',
        soul: 'You are a route-created agent.'
      }
    })
    expect(createdAgent.status).toBe(201)
    await expect(createdAgent.json()).resolves.toMatchObject({
      agent: {
        uid: agentUid,
        displayName: 'Route Test Agent'
      }
    })

    const human = await authedFetch('/api/console/human-users', {
      method: 'POST',
      body: { uid: humanUid, email: `${humanUid}@example.com` }
    })
    expect(human.status).toBe(201)
    await expect(human.json()).resolves.toMatchObject({
      human: {
        principal: {
          uid: humanUid,
          type: 'human',
          status: 'active'
        },
        humanUser: {
          email: `${humanUid}@example.com`
        }
      }
    })

    const disabledHuman = await authedFetch(`/api/console/human-users/${humanUid}`, {
      method: 'PUT',
      body: { status: 'disabled' }
    })
    expect(disabledHuman.status).toBe(200)
    await expect(disabledHuman.json()).resolves.toMatchObject({
      human: {
        principal: {
          status: 'disabled'
        }
      }
    })

    const group = await authedFetch('/api/console/principal-groups', {
      method: 'POST',
      body: { name: groupName, kind: 'static' }
    })
    expect(group.status).toBe(201)
    const groupBody = (await group.json()) as { group: { id: string; name: string } }
    expect(groupBody.group.name).toBe(groupName)

    const groups = await authedFetch('/api/console/principal-groups')
    expect(groups.status).toBe(200)
    expect(
      ((await groups.json()) as { groups: Array<{ name: string; membershipCount: number }> }).groups.some(
        item => item.name === groupName && item.membershipCount === 0
      )
    ).toBe(true)

    const soul = await authedFetch(`/api/console/agents/${agentUid}/soul`)
    expect(soul.status).toBe(200)
    expect(((await soul.json()) as { content: string | null }).content).toBe('You are a route-created agent.')

    const updatedSoul = await authedFetch(`/api/console/agents/${agentUid}/soul`, {
      method: 'PUT',
      body: { content: 'You are a route-test agent.' }
    })
    expect(updatedSoul.status).toBe(200)
    await expect(updatedSoul.json()).resolves.toEqual({ content: 'You are a route-test agent.' })

    const mission = await authedFetch(`/api/console/agents/${agentUid}/mission`)
    expect(mission.status).toBe(200)
    expect(((await mission.json()) as { content: string | null }).content).toBe('Start with route mission.')

    const updatedMission = await authedFetch(`/api/console/agents/${agentUid}/mission`, {
      method: 'PUT',
      body: { content: 'Keep route tests grounded.' }
    })
    expect(updatedMission.status).toBe(200)
    await expect(updatedMission.json()).resolves.toEqual({ content: 'Keep route tests grounded.' })

    const entries = await authedFetch(`/api/console/agents/${agentUid}/library-entries`)
    expect(entries.status).toBe(200)
    const entryPaths = ((await entries.json()) as { entries: Array<{ virtualPath: string }> }).entries.map(
      entry => entry.virtualPath
    )
    expect(entryPaths).toContain('SOUL.md')
    expect(entryPaths).toContain('MISSION.md')

    const overview = await authedFetch('/api/console/overview')
    expect(overview.status).toBe(200)
    await expect(overview.json()).resolves.toMatchObject({
      overview: {
        counts: {
          agents: expect.any(Number),
          humanUsers: expect.any(Number),
          principalGroups: expect.any(Number)
        },
        resources: expect.arrayContaining([
          expect.objectContaining({ id: 'agents' }),
          expect.objectContaining({ id: 'skills' }),
          expect.objectContaining({ id: 'workers' })
        ])
      }
    })

    const deletedGroup = await authedFetch(`/api/console/principal-groups/${groupBody.group.id}`, { method: 'DELETE' })
    expect(deletedGroup.status).toBe(204)
  })
})

describe('console settings routes', () => {
  it('reads and updates installation settings', async () => {
    const originalLocale = await appConfigService.get(AppI18nDefaultLocaleConfig)
    const originalTimezone = await appConfigService.refreshByKey(SystemTimezoneConfig.key)
    const originalPublicBaseUrl = await appConfigService.get(AdminAuthPublicBaseUrlConfig)

    try {
      const initial = await authedFetch('/api/console/settings')
      expect(initial.status).toBe(200)
      await expect(initial.json()).resolves.toMatchObject({
        settings: {
          defaultLocale: expect.any(String),
          availableLocales: expect.arrayContaining([expect.objectContaining({ value: 'en-US' })])
        }
      })

      const updated = await authedFetch('/api/console/settings', {
        method: 'PUT',
        body: {
          defaultLocale: 'zh-Hans-CN',
          timezone: 'Asia/Shanghai',
          publicBaseUrl: 'https://console.example.com'
        }
      })
      expect(updated.status).toBe(200)
      await expect(updated.json()).resolves.toMatchObject({
        settings: {
          defaultLocale: 'zh-Hans-CN',
          timezone: 'Asia/Shanghai',
          effectiveTimezone: 'Asia/Shanghai',
          publicBaseUrl: 'https://console.example.com'
        }
      })
    } finally {
      await restoreConfig(AppI18nDefaultLocaleConfig, originalLocale)
      await restoreConfig(SystemTimezoneConfig, originalTimezone)
      await restoreConfig(AdminAuthPublicBaseUrlConfig, originalPublicBaseUrl)
    }
  })

  it('rejects invalid settings with 422', async () => {
    const badTimezone = await authedFetch('/api/console/settings', {
      method: 'PUT',
      body: { timezone: 'Not/AZone' }
    })
    expect(badTimezone.status).toBe(422)

    const badUrl = await authedFetch('/api/console/settings', {
      method: 'PUT',
      body: { publicBaseUrl: 'not-a-url' }
    })
    expect(badUrl.status).toBe(422)

    const badLocale = await authedFetch('/api/console/settings', {
      method: 'PUT',
      body: { defaultLocale: 'fr-FR' }
    })
    expect(badLocale.status).toBe(422)
  })
})

describe('console web tool routes', () => {
  it('reads, updates, and clears web tool adapter configuration', async () => {
    const originalSearchProvider = await appConfigService.get(WebSearchProviderConfig)
    const originalExtractProvider = await appConfigService.get(WebExtractProviderConfig)
    const originalExaApiKey = await appConfigService.get(WebExaApiKey)
    const originalParallelApiKey = await appConfigService.get(WebParallelApiKey)
    const originalJinaApiKey = await appConfigService.get(WebJinaApiKey)

    try {
      const initial = await authedFetch('/api/console/web-tools')
      expect(initial.status).toBe(200)
      await expect(initial.json()).resolves.toMatchObject({
        webTools: {
          providers: expect.arrayContaining([
            expect.objectContaining({ id: 'exa', supports: expect.arrayContaining(['search', 'extract']) }),
            expect.objectContaining({ id: 'webfetch', supports: expect.arrayContaining(['extract']) })
          ])
        }
      })

      const updated = await authedFetch('/api/console/web-tools', {
        method: 'PUT',
        body: {
          searchProvider: 'parallel',
          extractProvider: 'jina',
          exaApiKey: 'exa-route-secret',
          parallelApiKey: 'parallel-route-secret',
          jinaApiKey: 'jina-route-secret'
        }
      })
      expect(updated.status).toBe(200)
      await expect(updated.json()).resolves.toMatchObject({
        webTools: {
          searchProvider: 'parallel',
          extractProvider: 'jina',
          apiKeys: {
            exa: { present: true, masked: '********' },
            parallel: { present: true, masked: '********' },
            jina: { present: true, masked: '********' }
          }
        }
      })

      const cleared = await authedFetch('/api/console/web-tools', {
        method: 'PUT',
        body: {
          searchProvider: null,
          exaApiKey: null
        }
      })
      expect(cleared.status).toBe(200)
      await expect(cleared.json()).resolves.toMatchObject({
        webTools: {
          searchProvider: null,
          extractProvider: 'jina',
          apiKeys: {
            exa: { present: false, masked: null },
            parallel: { present: true, masked: '********' }
          }
        }
      })
    } finally {
      await restoreConfig(WebSearchProviderConfig, originalSearchProvider)
      await restoreConfig(WebExtractProviderConfig, originalExtractProvider)
      await restoreConfig(WebExaApiKey, originalExaApiKey)
      await restoreConfig(WebParallelApiKey, originalParallelApiKey)
      await restoreConfig(WebJinaApiKey, originalJinaApiKey)
      await authedFetch('/api/console/web-tools', { method: 'PUT', body: {} })
    }
  })
})

async function restoreConfig<TValue extends AppConfigJsonValue>(
  definition: AppConfigDefinition<TValue>,
  value: TValue | undefined
): Promise<void> {
  if (value === undefined) await appConfigService.delete(definition)
  else await appConfigService.set(definition, value)
}

async function clearTestRows(): Promise<void> {
  await DB.delete(LlmProviders).where(like(LlmProviders.providerId, `${providerPrefix}%`))
  await DB.delete(PrincipalGroups).where(like(PrincipalGroups.name, `${testPrefix}%`))
  await DB.delete(Principals).where(like(Principals.uid, `${testPrefix}%`))
}

async function authedFetch(path: string, init: { method?: string; body?: unknown } = {}): Promise<Response> {
  return webServer.handle(
    new Request(`http://localhost${path}`, {
      method: init.method ?? 'GET',
      headers: {
        Origin: 'http://localhost',
        'Content-Type': 'application/json',
        Cookie: adminCookie
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
  throw new Error('LLM catalog did not expose any models')
}
