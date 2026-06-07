import 'reflect-metadata'
import { afterEach, beforeEach, describe, expect, it } from 'bun:test'
import { getModels, getProviders } from '@earendil-works/pi-ai'
import { like } from 'drizzle-orm'
import { loadTestEnvFiles } from '@/common/tests/load-test-env'

await loadTestEnvFiles()

const { DB } = await import('@/common/database')
const { LlmProviders, Principals } = await import('@/common/db-schema')
const { createWebServer } = await import('@/core/web-server')
const { ensureBuiltInAdminGroup } = await import('@/principals/authorization/groups')
const { insertMembership } = await import('@/principals/authorization/memberships')
const { createHuman } = await import('@/principals/human-users/service')
const { ADMIN_SESSION_COOKIE, cookieHeader, createAdminSessionCookie } = await import('@/principals/admin-auth/session')

const webServer = await createWebServer({ serveStaticAssets: false })
const testPrefix = `test_console_routes_${Date.now()}_${Math.random().toString(36).slice(2)}`.toLowerCase()
const providerPrefix = `crp_${Date.now().toString(36)}_${Math.random().toString(36).slice(2, 8)}`.toLowerCase()
const catalog = firstCatalogModel()
let adminCookie = ''

beforeEach(async () => {
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
        piProvider: catalog.provider,
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
        piProvider: catalog.provider,
        apiKey: {
          present: true,
          masked: '********'
        }
      }
    })

    const listed = await authedFetch('/api/console/llm-providers')
    expect(listed.status).toBe(200)
    expect(((await listed.json()) as { providers: Array<{ providerId: string }> }).providers.some(provider => provider.providerId === providerId))
      .toBe(true)

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
    expect(((await models.json()) as { models: Array<{ id: string }> }).models.some(model => model.id === catalog.model.id))
      .toBe(true)

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

async function clearTestRows(): Promise<void> {
  await DB.delete(LlmProviders).where(like(LlmProviders.providerId, `${providerPrefix}%`))
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
  throw new Error('Pi catalog did not expose any models')
}
