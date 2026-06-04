import 'reflect-metadata'
import { describe, expect, it } from 'bun:test'
import { loadTestEnvFiles } from '../../common/tests/load-test-env'

await loadTestEnvFiles()

const { IdentityProviderRuntime } = await import('./runtime')
const { IdentityProviderAdapterRegistry, UnknownIdentityProviderAdapterError } = await import('./registry')
const { ActiveIdentityProvidersConfig, IdentityProviderConfigPattern, identityProviderConfigKey } =
  await import('./config')

describe('identity provider config', () => {
  it('rejects duplicate active provider ids', () => {
    expect(() =>
      ActiveIdentityProvidersConfig.schema.parse([
        { providerId: 'corp-main', adapter: 'mock' },
        { providerId: 'corp-main', adapter: 'mock' }
      ])
    ).toThrow('duplicate identity providerId: corp-main')
  })

  it('rejects provider ids outside the shared external identity namespace contract', () => {
    expect(() => ActiveIdentityProvidersConfig.schema.parse([{ providerId: 'CorpMain', adapter: 'mock' }])).toThrow()
  })

  it('uses the globally unique provider id as the provider config key', () => {
    expect(identityProviderConfigKey('lark-main')).toBe('identity_providers.lark-main')
    expect(IdentityProviderConfigPattern.keyPattern.test('identity_providers.lark-main')).toBe(true)
    expect(IdentityProviderConfigPattern.keyPattern.test('identity_providers.lark.lark-main')).toBe(false)
    expect(() => identityProviderConfigKey('active')).toThrow('reserved identity providerId')
  })
})

describe('IdentityProviderRuntime', () => {
  it('starts configured providers through the registered adapter factory', async () => {
    const registry = new IdentityProviderAdapterRegistry()
    const contexts: unknown[] = []
    registry.register({
      id: 'mock',
      create: context => {
        contexts.push(context)
        return {}
      }
    })

    const runtime = new IdentityProviderRuntime()
    const stats = await runtime.start({
      registry,
      getActiveProviders: async () => [{ providerId: 'corp-main', adapter: 'mock', enabled: true }],
      getProviderConfig: async () => ({ appId: 'cli_test' }),
      getPublicBaseUrl: async () => 'https://admin.example.com',
      isProduction: true
    })

    expect(stats).toEqual({
      activeProviders: ['corp-main'],
      startedProviders: ['corp-main'],
      degradedProviders: []
    })
    expect(contexts).toHaveLength(1)
    expect(contexts[0]).toMatchObject({
      providerId: 'corp-main',
      config: { appId: 'cli_test' },
      publicBaseUrl: 'https://admin.example.com',
      isProduction: true
    })

    await runtime.stop()
  })

  it('fails startup when the active list references an unknown adapter', async () => {
    const runtime = new IdentityProviderRuntime()

    await expect(
      runtime.start({
        registry: new IdentityProviderAdapterRegistry(),
        getActiveProviders: async () => [{ providerId: 'corp-main', adapter: 'missing', enabled: true }],
        getProviderConfig: async () => undefined,
        getPublicBaseUrl: async () => undefined
      })
    ).rejects.toThrow(UnknownIdentityProviderAdapterError)
  })

  it('logs degraded full sync failures and retries without failing startup', async () => {
    const registry = new IdentityProviderAdapterRegistry()
    const logs: Array<{ level: string; data: any; message: string }> = []
    let attempts = 0
    registry.register({
      id: 'mock',
      create: () => ({
        fullSync: async () => {
          attempts += 1
          throw new Error('lark unavailable')
        }
      })
    })

    const runtime = new IdentityProviderRuntime()
    const stats = await runtime.start({
      registry,
      getActiveProviders: async () => [{ providerId: 'corp-main', adapter: 'mock', enabled: true }],
      getProviderConfig: async () => ({}),
      getPublicBaseUrl: async () => undefined,
      logger: captureLogger(logs),
      retryMs: 5
    })

    expect(stats.startedProviders).toEqual(['corp-main'])
    expect(stats.degradedProviders).toEqual(['corp-main'])
    expect(attempts).toBe(1)
    await Bun.sleep(20)
    await runtime.stop()

    expect(attempts).toBeGreaterThanOrEqual(2)
    expect(logs).toContainEqual(
      expect.objectContaining({
        level: 'warn',
        message: 'Identity provider degraded; retry scheduled',
        data: expect.objectContaining({
          providerId: 'corp-main',
          adapter: 'mock',
          stage: 'full_sync',
          retryMs: 5
        })
      })
    )
  })
})

function captureLogger(logs: Array<{ level: string; data: any; message: string }>) {
  return {
    info(data: unknown, message: string) {
      logs.push({ level: 'info', data, message })
    },
    warn(data: unknown, message: string) {
      logs.push({ level: 'warn', data, message })
    },
    error(data: unknown, message: string) {
      logs.push({ level: 'error', data, message })
    }
  }
}
