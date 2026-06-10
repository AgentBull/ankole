import { afterEach, beforeEach, describe, expect, it } from 'bun:test'
import { getModels, getProviders } from '@earendil-works/pi-ai'
import { eq, like } from 'drizzle-orm'
import { loadTestEnvFiles } from '@/common/tests/load-test-env'

await loadTestEnvFiles()

const { DB } = await import('@/common/database')
const { LlmProviders, Principals } = await import('@/common/db-schema')
const { createAgent } = await import('@/principals/agents/service')
const {
  checkLlmProvider,
  createLlmProvider,
  deleteLlmProvider,
  listLlmProviderModels,
  resolveLlmProviderModelProfile,
  updateLlmProvider,
  upsertLlmProvider
} = await import('./service')

const testPrefix = `tlp_${Date.now().toString(36)}_${Math.random().toString(36).slice(2, 8)}`.toLowerCase()
const catalog = firstCatalogModel()
const originalOpenAiApiKey = Bun.env.OPENAI_API_KEY

beforeEach(clearTestRows)

afterEach(async () => {
  if (originalOpenAiApiKey === undefined) delete Bun.env.OPENAI_API_KEY
  else Bun.env.OPENAI_API_KEY = originalOpenAiApiKey
  await clearTestRows()
})

describe('LLM provider service', () => {
  it('validates ids and Pi provider/model references', async () => {
    await expect(
      createLlmProvider({
        providerId: 'BadProvider',
        piProvider: catalog.provider,
        apiKey: 'sk-test'
      })
    ).rejects.toThrow()

    await expect(
      createLlmProvider({
        providerId: providerId('unknown_pi'),
        piProvider: 'missing-pi-provider',
        apiKey: 'sk-test'
      })
    ).rejects.toMatchObject({
      status: 422,
      message: 'unknown Pi provider: missing-pi-provider'
    })

    const provider = await createLlmProvider({
      providerId: providerId('models'),
      piProvider: catalog.provider,
      apiKey: 'sk-test'
    })
    expect(provider.apiKey).toEqual({ present: true, masked: '********' })
    expect((await listLlmProviderModels(provider.providerId)).some(model => model.id === catalog.model.id)).toBe(true)
  })

  it('encrypts keys and preserves, updates, clears, and masks them on write', async () => {
    const id = providerId('keys')
    await createLlmProvider({
      providerId: id,
      piProvider: catalog.provider,
      apiKey: 'sk-original'
    })

    const storedOriginal = await rawProvider(id)
    expect(storedOriginal?.encryptedApiKey).toBeTruthy()
    expect(storedOriginal?.encryptedApiKey).not.toContain('sk-original')

    await upsertLlmProvider({
      providerId: id,
      baseUrl: 'https://llm.example.test/v1'
    })
    expect((await rawProvider(id))?.encryptedApiKey).toBe(storedOriginal?.encryptedApiKey)

    await updateLlmProvider({
      providerId: id,
      apiKey: 'sk-updated'
    })
    const storedUpdated = await rawProvider(id)
    expect(storedUpdated?.encryptedApiKey).toBeTruthy()
    expect(storedUpdated?.encryptedApiKey).not.toBe(storedOriginal?.encryptedApiKey)
    expect(storedUpdated?.encryptedApiKey).not.toContain('sk-updated')

    await updateLlmProvider({
      providerId: id,
      apiKey: ''
    })
    expect((await rawProvider(id))?.encryptedApiKey).toBeNull()
  })

  it('fails resolver and check when only env has an API key', async () => {
    const id = providerId('missing_key')
    Bun.env.OPENAI_API_KEY = 'sk-env-should-not-be-used'
    await createLlmProvider({
      providerId: id,
      piProvider: catalog.provider,
      apiKey: 'sk-db'
    })
    await updateLlmProvider({
      providerId: id,
      apiKey: null
    })

    await expect(
      checkLlmProvider({
        providerId: id,
        model: catalog.model.id
      })
    ).rejects.toMatchObject({
      status: 422,
      message: `llm provider api key is not configured: ${id}`
    })

    await expect(
      resolveLlmProviderModelProfile({
        providerId: id,
        model: catalog.model.id,
        reasoning: 'medium'
      })
    ).rejects.toMatchObject({
      status: 422,
      message: `llm provider api key is not configured: ${id}`
    })
  })

  it('resolves model/baseUrl/header/options overrides with profile parameters winning', async () => {
    const id = providerId('resolve')
    await createLlmProvider({
      providerId: id,
      piProvider: catalog.provider,
      baseUrl: 'https://llm.example.test/v1',
      apiKey: 'sk-db',
      providerOptions: {
        headers: {
          'x-bullx-test': 'yes'
        },
        timeoutMs: 1200,
        websocketConnectTimeoutMs: 300,
        maxRetries: 4,
        maxRetryDelayMs: 900,
        transport: 'websocket',
        compat: {
          supportsDeveloperRole: false
        }
      }
    })

    const resolved = await resolveLlmProviderModelProfile({
      providerId: id,
      model: catalog.model.id,
      reasoning: 'high',
      temperature: 0.2,
      maxTokens: 123,
      cacheRetention: 'long',
      transport: 'sse'
    })

    expect(resolved.config).toMatchObject({
      providerId: id,
      piProvider: catalog.provider,
      model: catalog.model.id,
      reasoning: 'high'
    })
    expect(resolved.model.baseUrl).toBe('https://llm.example.test/v1')
    expect(resolved.model.headers).toMatchObject({ 'x-bullx-test': 'yes' })
    expect(resolved.model.compat).toMatchObject({ supportsDeveloperRole: false })
    expect(resolved.options).toMatchObject({
      apiKey: 'sk-db',
      timeoutMs: 1200,
      websocketConnectTimeoutMs: 300,
      maxRetries: 4,
      maxRetryDelayMs: 900,
      transport: 'sse',
      cacheRetention: 'long',
      maxTokens: 123,
      reasoning: 'high',
      temperature: 0.2
    })
  })

  it('rejects non-secret providerOptions headers that look like credentials', async () => {
    await expect(
      createLlmProvider({
        providerId: providerId('secret_header'),
        piProvider: catalog.provider,
        apiKey: 'sk-db',
        providerOptions: {
          headers: {
            authorization: 'Bearer secret'
          }
        }
      })
    ).rejects.toMatchObject({
      status: 422
    })
  })

  it('guards delete while an agent metadata model role references the provider', async () => {
    const id = providerId('ref_guard')
    await createLlmProvider({
      providerId: id,
      piProvider: catalog.provider,
      apiKey: 'sk-db'
    })
    await createAgent({
      uid: agentUid('ref_guard'),
      metadata: {
        ai_agent: {
          models: {
            primary: {
              providerId: id,
              model: catalog.model.id
            }
          }
        }
      }
    })

    await expect(deleteLlmProvider(id)).rejects.toMatchObject({
      status: 409,
      message: `llm provider is used by agent models: ${agentUid('ref_guard')}:primary`
    })

    await DB.delete(Principals).where(eq(Principals.uid, agentUid('ref_guard')))
    await deleteLlmProvider(id)
    expect(await rawProvider(id)).toBeUndefined()
  })
})

async function clearTestRows(): Promise<void> {
  await DB.delete(Principals).where(like(Principals.uid, `${testPrefix}%`))
  await DB.delete(LlmProviders).where(like(LlmProviders.providerId, `${testPrefix}%`))
}

async function rawProvider(providerId: string) {
  const [row] = await DB.select().from(LlmProviders).where(eq(LlmProviders.providerId, providerId)).limit(1)
  return row
}

function providerId(suffix: string): string {
  return `${testPrefix}_${suffix}`
}

function agentUid(suffix: string): string {
  return `${testPrefix}_${suffix}`
}

function firstCatalogModel() {
  for (const provider of getProviders()) {
    const [model] = getModels(provider as never)
    if (model) return { provider, model }
  }
  throw new Error('Pi catalog did not expose any models')
}
