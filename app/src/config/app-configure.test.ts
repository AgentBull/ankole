import 'reflect-metadata'
import { afterAll, describe, expect, it } from 'bun:test'
import { eq, sql } from 'drizzle-orm'
import { z } from 'zod'
import { loadTestEnvFiles } from '../common/tests/load-test-env'
import { AppConfigure, ConfigureKeyType } from '../common/db-schema/app-configure'

await loadTestEnvFiles()

const {
  AmbiguousAppConfigKeyError,
  AppConfigRegistry,
  AppConfigService,
  AppConfigStorageError,
  DuplicateAppConfigKeyError,
  DuplicateAppConfigPatternError,
  UnknownAppConfigKeyError,
  appConfigService,
  defineAppConfig,
  defineAppConfigPattern,
  registerAppConfigDefinitions,
  registerAppConfigPatterns
} = await import('./app-configure')
const { DB, jsonbParam } = await import('../common/database')

const testKeyPrefix = `__test.app_configure.${Date.now()}.${Math.random().toString(36).slice(2)}`

function key(name: string) {
  return `${testKeyPrefix}.${name}`
}

afterAll(async () => {
  await DB.delete(AppConfigure).where(eq(AppConfigure.key, key('plaintext')))
  await DB.delete(AppConfigure).where(eq(AppConfigure.key, key('encrypted')))
  await DB.delete(AppConfigure).where(eq(AppConfigure.key, key('encrypted_corrupt')))
  await DB.delete(AppConfigure).where(eq(AppConfigure.key, key('pattern.dynamic')))
})

describe('AppConfigRegistry', () => {
  it('rejects duplicate keys', () => {
    const registry = new AppConfigRegistry()
    const definition = defineAppConfig({
      key: 'test.duplicate',
      encrypted: false,
      schema: z.string()
    })

    registry.register([definition])

    expect(() => registry.register([definition])).toThrow(DuplicateAppConfigKeyError)
  })

  it('rejects duplicate dynamic pattern ids', () => {
    const registry = new AppConfigRegistry()
    const definition = defineAppConfigPattern({
      id: 'test.duplicate_pattern',
      keyPattern: /^test\.duplicate_pattern\.[a-z]+$/,
      encrypted: false,
      schema: z.string()
    })

    registry.registerPatterns([definition])

    expect(() => registry.registerPatterns([definition])).toThrow(DuplicateAppConfigPatternError)
  })

  it('rejects ambiguous dynamic pattern matches', () => {
    const registry = new AppConfigRegistry()
    registry.registerPatterns([
      defineAppConfigPattern({
        id: 'test.pattern_one',
        keyPattern: /^test\.ambiguous\.[a-z]+$/,
        encrypted: false,
        schema: z.string()
      }),
      defineAppConfigPattern({
        id: 'test.pattern_two',
        keyPattern: /^test\.ambiguous\.value$/,
        encrypted: false,
        schema: z.string()
      })
    ])

    expect(() => registry.require('test.ambiguous.value')).toThrow(AmbiguousAppConfigKeyError)
  })

  it('validates default values when definitions are created', () => {
    expect(() =>
      defineAppConfig({
        key: 'test.invalid_default',
        encrypted: false,
        schema: z.number(),
        defaultValue: 'not-a-number' as never
      })
    ).toThrow()
  })

  it('rejects unknown keys before the write path can persist them', async () => {
    const service = new AppConfigService(new AppConfigRegistry())

    await expect(service.setByKey('test.unknown', 'value')).rejects.toThrow(UnknownAppConfigKeyError)
  })

  it('validates values before the write path can persist them', async () => {
    const registry = new AppConfigRegistry()
    const service = new AppConfigService(registry)

    registry.register([
      defineAppConfig({
        key: 'test.validated',
        encrypted: false,
        schema: z.number()
      })
    ])

    await expect(service.setByKey('test.validated', 'not-a-number' as never)).rejects.toThrow()
  })
})

describe('AppConfigService database persistence', () => {
  it('roundtrips plaintext values and refreshes cache from the database', async () => {
    const definition = defineAppConfig({
      key: key('plaintext'),
      encrypted: false,
      schema: z.object({
        enabled: z.boolean(),
        limit: z.number().int()
      }),
      defaultValue: {
        enabled: false,
        limit: 0
      }
    })

    registerAppConfigDefinitions([definition])

    expect(await appConfigService.get(definition)).toEqual({ enabled: false, limit: 0 })

    await appConfigService.set(definition, { enabled: true, limit: 3 })
    expect(await appConfigureValueType(definition.key)).toBe('object')
    expect(await appConfigService.get(definition)).toEqual({ enabled: true, limit: 3 })

    await DB.update(AppConfigure)
      .set({
        value: jsonbParam({
          type: ConfigureKeyType.PLAINTEXT,
          value: {
            enabled: false,
            limit: 7
          }
        })
      })
      .where(eq(AppConfigure.key, definition.key))

    expect(await appConfigService.get(definition)).toEqual({ enabled: true, limit: 3 })
    await appConfigService.refreshAll()
    expect(await appConfigService.get(definition)).toEqual({ enabled: false, limit: 7 })

    await appConfigService.delete(definition)
    expect(await appConfigService.get(definition)).toEqual({ enabled: false, limit: 0 })
  })

  it('roundtrips encrypted values without storing plaintext', async () => {
    const definition = defineAppConfig({
      key: key('encrypted'),
      encrypted: true,
      schema: z.object({
        apiKey: z.string().min(1)
      })
    })

    registerAppConfigDefinitions([definition])

    await appConfigService.set(definition, { apiKey: 'secret-api-key' })

    const [row] = await DB.select().from(AppConfigure).where(eq(AppConfigure.key, definition.key)).limit(1)
    expect(await appConfigureValueType(definition.key)).toBe('object')
    expect(row?.value.type).toBe(ConfigureKeyType.CIPHER)
    expect(row?.value.value).toBeString()
    expect(row?.value.value).not.toContain('secret-api-key')

    expect(await appConfigService.refresh(definition)).toEqual({ apiKey: 'secret-api-key' })
  })

  it('does not cache corrupted encrypted values', async () => {
    const definition = defineAppConfig({
      key: key('encrypted_corrupt'),
      encrypted: true,
      schema: z.object({
        token: z.string()
      })
    })

    registerAppConfigDefinitions([definition])

    await appConfigService.set(definition, { token: 'original-token' })

    await DB.update(AppConfigure)
      .set({
        value: jsonbParam({
          type: ConfigureKeyType.CIPHER,
          value: 'not-a-valid-cipher'
        })
      })
      .where(eq(AppConfigure.key, definition.key))

    await expect(appConfigService.refresh(definition)).rejects.toThrow(AppConfigStorageError)

    await DB.delete(AppConfigure).where(eq(AppConfigure.key, definition.key))

    expect(await appConfigService.get(definition)).toBeUndefined()
  })

  it('roundtrips encrypted JSON object values through dynamic pattern keys', async () => {
    const pattern = defineAppConfigPattern({
      id: key('pattern'),
      keyPattern: new RegExp(`^${escapeRegExp(testKeyPrefix)}\\.pattern\\.[a-z]+$`),
      encrypted: true,
      schema: z.object({
        token: z.string().min(1),
        nested: z.object({
          enabled: z.boolean()
        })
      }),
      defaultValue: {
        token: 'default-token',
        nested: {
          enabled: false
        }
      }
    })
    const dynamicKey = key('pattern.dynamic')

    registerAppConfigPatterns([pattern])

    expect(await appConfigService.getByKey(dynamicKey)).toEqual({
      token: 'default-token',
      nested: {
        enabled: false
      }
    })

    await appConfigService.setByKey(dynamicKey, {
      token: 'runtime-token',
      nested: {
        enabled: true
      }
    })

    const [row] = await DB.select().from(AppConfigure).where(eq(AppConfigure.key, dynamicKey)).limit(1)
    expect(await appConfigureValueType(dynamicKey)).toBe('object')
    expect(row?.value.type).toBe(ConfigureKeyType.CIPHER)
    expect(row?.value.value).toBeString()
    expect(row?.value.value).not.toContain('runtime-token')

    expect(await appConfigService.refreshByKey(dynamicKey)).toEqual({
      token: 'runtime-token',
      nested: {
        enabled: true
      }
    })

    await expect(appConfigService.setByKey(key('pattern.unknown-key-shape'), { token: 'value' })).rejects.toThrow(
      UnknownAppConfigKeyError
    )
  })
})

function escapeRegExp(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
}

async function appConfigureValueType(key: string): Promise<string | undefined> {
  const rows = (await DB.execute(sql`
    SELECT jsonb_typeof(value) AS "valueType"
    FROM app_configure
    WHERE key = ${key}
    LIMIT 1
  `)) as unknown as Array<{ valueType: string }>

  return rows[0]?.valueType
}
