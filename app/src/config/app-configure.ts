import { aeadDecrypt, aeadEncrypt } from '@agentbull/bullx-native-addons'
import { eq, sql } from 'drizzle-orm'
import type { z } from 'zod'
import { DB, jsonbParam } from '../common/database'
import {
  AppConfigure,
  type ConfigureJsonValue,
  ConfigureKeyType,
  type ConfigureValue
} from '../common/db-schema/app-configure'
import { rootContainer, singleton } from '../common/di'
import { getSecretKey, SecretKeyPurpose } from '../common/kms'

/**
 * JSON value accepted by the app dynamic configuration store.
 *
 * Runtime app config is intentionally restricted to JSON-compatible values
 * because the backing table stores values in PostgreSQL `jsonb`, and encrypted
 * values are encrypted from a JSON string before persistence.
 */
export type AppConfigJsonValue = ConfigureJsonValue

/**
 * Declares one dynamic app configuration key.
 *
 * A definition is the write/read contract for a key. Call sites should not
 * write arbitrary database keys; they should first declare a key with its Zod
 * schema and storage policy, register that definition, then use the definition
 * object when reading or writing.
 *
 * Dynamic app config is separate from bootstrap config in {@link AppEnv}. Values
 * such as `DATABASE_URL`, `BULLX_SECRET_BASE`, and other process startup inputs
 * must stay in environment-derived bootstrap config because the database and
 * encryption key material are not available before startup. This module owns
 * values that can be changed at runtime, for example provider credentials or
 * feature settings once their owning module declares them.
 */
export interface AppConfigDefinition<TValue extends AppConfigJsonValue = AppConfigJsonValue> {
  /** Stable database key. Prefer namespaced keys such as `llm.openai.api_key`. */
  key: string
  /** Zod schema used before persistence and after database reads. */
  schema: z.ZodType<TValue>
  /** Whether the stored JSON value should be encrypted at rest. */
  encrypted: boolean
  /** Optional value returned when no database row exists. */
  defaultValue?: TValue
  /** Human-facing description for setup/admin surfaces. */
  description?: string
}

/**
 * Declares a family of runtime-computed app configuration keys.
 *
 * Pattern definitions are for keys whose full set cannot be known at module
 * import time, for example one encrypted provider-config object per
 * agent/channel pair. They still keep validation and encryption policy explicit;
 * unknown keys outside registered patterns remain rejected.
 */
export interface AppConfigPatternDefinition<TValue extends AppConfigJsonValue = AppConfigJsonValue> {
  /** Stable pattern id used for duplicate detection and diagnostics. */
  id: string
  /** Matches dynamic database keys that share one validation/encryption policy. */
  keyPattern: RegExp
  /** Zod schema used before persistence and after database reads. */
  schema: z.ZodType<TValue>
  /** Whether the stored JSON value should be encrypted at rest. */
  encrypted: boolean
  /** Optional value returned when no database row exists. */
  defaultValue?: TValue
  /** Human-facing description for setup/admin surfaces. */
  description?: string
}

/**
 * Extracts the runtime value type from an {@link AppConfigDefinition}.
 */
export type AppConfigDefinitionValue<TDefinition> =
  TDefinition extends AppConfigDefinition<infer TValue> ? TValue : never

/**
 * A concrete registered config policy, either exact-key or pattern-backed.
 */
export type AppConfigRegisteredDefinition<TValue extends AppConfigJsonValue = AppConfigJsonValue> =
  | AppConfigDefinition<TValue>
  | AppConfigPatternDefinition<TValue>

/**
 * Raised when two modules try to register the same configuration key.
 */
export class DuplicateAppConfigKeyError extends Error {
  constructor(key: string) {
    super(`App config key is already registered: ${key}`)
    this.name = 'DuplicateAppConfigKeyError'
  }
}

/**
 * Raised when two modules try to register the same dynamic pattern id.
 */
export class DuplicateAppConfigPatternError extends Error {
  constructor(id: string) {
    super(`App config pattern is already registered: ${id}`)
    this.name = 'DuplicateAppConfigPatternError'
  }
}

/**
 * Raised when code tries to read, write, refresh, or delete an unregistered key.
 */
export class UnknownAppConfigKeyError extends Error {
  constructor(key: string) {
    super(`App config key is not registered: ${key}`)
    this.name = 'UnknownAppConfigKeyError'
  }
}

/**
 * Raised when a runtime key matches more than one registered pattern.
 */
export class AmbiguousAppConfigKeyError extends Error {
  constructor(key: string, patternIds: readonly string[]) {
    super(`App config key matched multiple patterns: ${key} (${patternIds.join(', ')})`)
    this.name = 'AmbiguousAppConfigKeyError'
  }
}

/**
 * Raised when a database row cannot be decoded according to its registered
 * definition.
 *
 * This normally means the row has the wrong plaintext/cipher marker, encrypted
 * bytes cannot be decrypted with the current root secret, or stored JSON no
 * longer satisfies the definition's Zod schema.
 */
export class AppConfigStorageError extends Error {
  constructor(key: string, message: string, options?: ErrorOptions) {
    super(`Invalid app config storage for ${key}: ${message}`, options)
    this.name = 'AppConfigStorageError'
  }
}

/**
 * Creates a typed app config definition and validates its default value.
 *
 * This helper has no side effects. Modules should export definitions from their
 * own config files, then register them during module setup.
 *
 * @example
 * ```ts
 * import { z } from 'zod'
 * import { defineAppConfig, registerAppConfigDefinitions, appConfigService } from '@/config/app-configure'
 *
 * export const OpenAIAPIKey = defineAppConfig({
 *   key: 'llm.openai.api_key',
 *   encrypted: true,
 *   schema: z.string().min(1),
 *   description: 'OpenAI API key used by the LLM provider bridge'
 * })
 *
 * registerAppConfigDefinitions([OpenAIAPIKey])
 *
 * await appConfigService.set(OpenAIAPIKey, 'sk-...')
 * const apiKey = await appConfigService.get(OpenAIAPIKey)
 * ```
 */
export function defineAppConfig<TValue extends AppConfigJsonValue>(
  definition: AppConfigDefinition<TValue>
): AppConfigDefinition<TValue> {
  if (Object.hasOwn(definition, 'defaultValue')) definition.schema.parse(definition.defaultValue)

  return definition
}

/**
 * Creates a typed dynamic app config pattern and validates its default value.
 *
 * This helper is side-effect free. Registration happens separately through
 * `registerAppConfigPatterns(...)`.
 */
export function defineAppConfigPattern<TValue extends AppConfigJsonValue>(
  definition: AppConfigPatternDefinition<TValue>
): AppConfigPatternDefinition<TValue> {
  if (Object.hasOwn(definition, 'defaultValue')) definition.schema.parse(definition.defaultValue)

  return definition
}

/**
 * In-memory registry for dynamic app config definitions.
 *
 * The registry is deliberately stricter than the database table: only registered
 * keys can be used. That keeps the in-memory cache bounded by the declared
 * config surface, prevents typo-created database rows, and makes encryption and
 * validation policy visible at the definition site instead of at call sites.
 */
@singleton()
export class AppConfigRegistry {
  private readonly definitions = new Map<string, AppConfigDefinition>()
  private readonly patternDefinitions = new Map<string, AppConfigPatternDefinition>()

  register(definitions: readonly AppConfigDefinition[]): void {
    for (const definition of definitions) this.registerOne(definition)
  }

  registerOne(definition: AppConfigDefinition): void {
    if (this.definitions.has(definition.key)) throw new DuplicateAppConfigKeyError(definition.key)

    if (Object.hasOwn(definition, 'defaultValue')) definition.schema.parse(definition.defaultValue)

    this.definitions.set(definition.key, definition)
  }

  registerPatterns(definitions: readonly AppConfigPatternDefinition[]): void {
    for (const definition of definitions) this.registerPattern(definition)
  }

  registerPattern(definition: AppConfigPatternDefinition): void {
    if (this.patternDefinitions.has(definition.id)) throw new DuplicateAppConfigPatternError(definition.id)

    if (Object.hasOwn(definition, 'defaultValue')) definition.schema.parse(definition.defaultValue)

    this.patternDefinitions.set(definition.id, definition)
  }

  get<TDefinition extends AppConfigDefinition>(definition: TDefinition): TDefinition {
    const registered = this.definitions.get(definition.key)
    if (!registered) throw new UnknownAppConfigKeyError(definition.key)

    return registered as TDefinition
  }

  /**
   * Resolves either an exact definition or a registered dynamic pattern.
   *
   * Use this only for runtime-computed keys such as plugin-owned
   * `agents.<agent_uid>.<channel>` config. Static module config should use
   * `get(definition)` so typos cannot be accidentally accepted by a broad
   * pattern.
   */
  getByKey(key: string): AppConfigRegisteredDefinition | undefined {
    return this.resolve(key)
  }

  /**
   * Like `getByKey`, but throws when no exact definition or pattern matches.
   */
  require<TDefinition extends AppConfigRegisteredDefinition = AppConfigRegisteredDefinition>(key: string): TDefinition {
    const definition = this.resolve(key)
    if (!definition) throw new UnknownAppConfigKeyError(key)

    return definition as TDefinition
  }

  list(): AppConfigDefinition[] {
    return [...this.definitions.values()]
  }

  listPatterns(): AppConfigPatternDefinition[] {
    return [...this.patternDefinitions.values()]
  }

  /**
   * Exact keys take precedence over patterns. If multiple patterns match, the
   * key is rejected so encryption and validation policy never depends on module
   * import order.
   */
  private resolve(key: string): AppConfigRegisteredDefinition | undefined {
    const exact = this.definitions.get(key)
    if (exact) return exact

    const matches = this.listPatterns().filter(definition => appConfigPatternMatches(definition, key))
    if (matches.length > 1) {
      throw new AmbiguousAppConfigKeyError(
        key,
        matches.map(definition => definition.id)
      )
    }

    return matches[0]
  }
}

/**
 * Reads and writes dynamic app config values through PostgreSQL.
 *
 * The service owns a process-local in-memory cache. Cache entries are bounded by
 * registered keys, updated immediately after writes, evicted after deletes, and
 * reloaded only through `refresh`, `refreshByKey`, or `refreshRegisteredExactKeys`. There is no TTL by default:
 * database config is a small declared surface, not an unbounded request cache,
 * and explicit invalidation keeps the runtime model easier to reason about.
 */
@singleton()
export class AppConfigService {
  private readonly cache = new Map<string, AppConfigJsonValue>()

  constructor(private readonly registry: AppConfigRegistry = rootContainer.resolve(AppConfigRegistry)) {}

  /**
   * Reads a typed config value by definition.
   *
   * Resolution order is in-memory cache, database row, then definition default.
   * There is no environment fallback here; bootstrap environment belongs to
   * `AppEnv`, not the dynamic database config layer.
   */
  async get<TDefinition extends AppConfigDefinition>(
    definition: TDefinition
  ): Promise<AppConfigDefinitionValue<TDefinition> | undefined> {
    const registered = this.registry.get(definition)
    return this.getWithDefinition(registered.key, registered) as Promise<
      AppConfigDefinitionValue<TDefinition> | undefined
    >
  }

  /**
   * Reads a config value by runtime key.
   *
   * This is the entry point for dynamic pattern-backed keys. Callers lose the
   * compile-time value type that exact definitions provide, so it should be used
   * only when the key is genuinely computed at runtime.
   */
  async getByKey<TValue extends AppConfigJsonValue = AppConfigJsonValue>(key: string): Promise<TValue | undefined> {
    const definition = this.registry.require<AppConfigRegisteredDefinition<TValue>>(key)
    return this.getWithDefinition(key, definition)
  }

  private async getWithDefinition<TValue extends AppConfigJsonValue>(
    key: string,
    definition: AppConfigRegisteredDefinition<TValue>
  ): Promise<TValue | undefined> {
    const cached = this.cache.get(key)
    if (cached !== undefined) return definition.schema.parse(cached)

    const loaded = await this.loadFromDatabase(key, definition)
    if (loaded !== undefined) return loaded

    if (Object.hasOwn(definition, 'defaultValue')) return definition.schema.parse(definition.defaultValue)

    return undefined
  }

  /**
   * Validates and persists a typed config value by definition.
   *
   * Writes update both PostgreSQL and the process-local cache. Encrypted
   * definitions are stored as cipher text produced from `JSON.stringify(value)`
   * using a per-key database encryption key derived from the root secret.
   */
  async set<TDefinition extends AppConfigDefinition>(
    definition: TDefinition,
    value: AppConfigDefinitionValue<TDefinition>
  ): Promise<AppConfigDefinitionValue<TDefinition>> {
    const registered = this.registry.get(definition)
    return this.setWithDefinition(registered.key, registered, value) as Promise<AppConfigDefinitionValue<TDefinition>>
  }

  /**
   * Validates and persists a config value by runtime key.
   */
  async setByKey<TValue extends AppConfigJsonValue>(key: string, value: TValue): Promise<TValue> {
    const definition = this.registry.require<AppConfigRegisteredDefinition<TValue>>(key)
    return this.setWithDefinition(key, definition, value)
  }

  private async setWithDefinition<TValue extends AppConfigJsonValue>(
    key: string,
    definition: AppConfigRegisteredDefinition<TValue>,
    value: TValue
  ): Promise<TValue> {
    const parsedValue = definition.schema.parse(value)
    const storedValue = this.serializeValue(key, definition, parsedValue)

    await DB.insert(AppConfigure)
      .values({
        key,
        value: jsonbParam(storedValue)
      })
      .onConflictDoUpdate({
        target: AppConfigure.key,
        set: {
          value: jsonbParam(storedValue),
          updatedAt: sql`CURRENT_TIMESTAMP`
        }
      })

    this.cache.set(key, parsedValue)
    return parsedValue
  }

  /**
   * Deletes a typed config value from PostgreSQL and evicts it from cache.
   */
  async delete<TDefinition extends AppConfigDefinition>(definition: TDefinition): Promise<void> {
    const registered = this.registry.get(definition)
    await this.deleteWithDefinition(registered.key)
  }

  /**
   * Deletes a config value by runtime key.
   */
  async deleteByKey(key: string): Promise<void> {
    this.registry.require(key)
    await this.deleteWithDefinition(key)
  }

  private async deleteWithDefinition(key: string): Promise<void> {
    await DB.delete(AppConfigure).where(eq(AppConfigure.key, key))
    this.cache.delete(key)
  }

  /**
   * Evicts one key from cache and reloads it from PostgreSQL.
   *
   * Use this when another process or an admin path may have updated the row
   * outside this service instance.
   */
  async refresh<TDefinition extends AppConfigDefinition>(
    definition: TDefinition
  ): Promise<AppConfigDefinitionValue<TDefinition> | undefined> {
    const registered = this.registry.get(definition)
    return this.refreshWithDefinition(registered.key, registered) as Promise<
      AppConfigDefinitionValue<TDefinition> | undefined
    >
  }

  /**
   * Evicts and reloads a runtime key, including pattern-backed keys.
   */
  async refreshByKey<TValue extends AppConfigJsonValue = AppConfigJsonValue>(key: string): Promise<TValue | undefined> {
    const definition = this.registry.require<AppConfigRegisteredDefinition<TValue>>(key)
    return this.refreshWithDefinition(key, definition)
  }

  private async refreshWithDefinition<TValue extends AppConfigJsonValue>(
    key: string,
    definition: AppConfigRegisteredDefinition<TValue>
  ): Promise<TValue | undefined> {
    this.cache.delete(key)
    return this.loadFromDatabase(key, definition)
  }

  /**
   * Clears the process-local cache and reloads every *registered exact* database
   * value.
   *
   * Pattern-backed keys (e.g. `agents.<uid>.<channel>`) are loaded lazily through
   * `getByKey`/`refreshByKey` and are intentionally NOT refreshed here, because the
   * service does not enumerate concrete keys for a pattern. The name reflects that
   * narrower contract; use `refreshByKey` to invalidate a specific pattern key.
   */
  async refreshRegisteredExactKeys(): Promise<void> {
    this.cache.clear()

    for (const definition of this.registry.list()) await this.loadFromDatabase(definition.key, definition)
  }

  listDefinitions(): AppConfigDefinition[] {
    return this.registry.list()
  }

  private async loadFromDatabase<TValue extends AppConfigJsonValue>(
    key: string,
    definition: AppConfigRegisteredDefinition<TValue>
  ): Promise<TValue | undefined> {
    const [row] = await DB.select().from(AppConfigure).where(eq(AppConfigure.key, key)).limit(1)
    if (!row) return undefined

    const value = this.deserializeValue(key, definition, row.value)
    this.cache.set(key, value)
    return value
  }

  private serializeValue<TValue extends AppConfigJsonValue>(
    key: string,
    definition: AppConfigRegisteredDefinition<TValue>,
    value: TValue
  ): ConfigureValue {
    if (!definition.encrypted) {
      return {
        type: ConfigureKeyType.PLAINTEXT,
        value
      }
    }

    return {
      type: ConfigureKeyType.CIPHER,
      value: aeadEncrypt(JSON.stringify(value), this.encryptionKey(key))
    }
  }

  private deserializeValue<TValue extends AppConfigJsonValue>(
    key: string,
    definition: AppConfigRegisteredDefinition<TValue>,
    storedValue: ConfigureValue
  ): TValue {
    storedValue = this.normalizeStoredValue(key, storedValue)

    if (definition.encrypted) {
      if (storedValue.type !== ConfigureKeyType.CIPHER || typeof storedValue.value !== 'string') {
        throw new AppConfigStorageError(key, 'expected encrypted string value')
      }

      try {
        const plainText = aeadDecrypt(storedValue.value, this.encryptionKey(key)).toString('utf-8')
        return definition.schema.parse(JSON.parse(plainText))
      } catch (error) {
        throw new AppConfigStorageError(key, 'failed to decrypt or validate value', { cause: error })
      }
    }

    if (storedValue.type !== ConfigureKeyType.PLAINTEXT) {
      throw new AppConfigStorageError(key, 'expected plaintext value')
    }

    return definition.schema.parse(storedValue.value)
  }

  private normalizeStoredValue(key: string, storedValue: ConfigureValue | string): ConfigureValue {
    if (typeof storedValue !== 'string') return storedValue

    try {
      const parsed = JSON.parse(storedValue) as ConfigureValue
      if (!parsed || typeof parsed !== 'object') throw new Error('stored value is not an object')
      return parsed
    } catch (error) {
      throw new AppConfigStorageError(key, 'expected JSON object value', { cause: error })
    }
  }

  private encryptionKey(key: string): string {
    return getSecretKey(SecretKeyPurpose.DATABASE_ENCRYPTION, `app_configure:${key}`)
  }
}

/**
 * Registers dynamic app config definitions in the root DI container.
 *
 * Import-time registration is acceptable for static app modules. Plugin modules
 * should call this from their activation path so their keys become available
 * only when the plugin is loaded.
 */
export function registerAppConfigDefinitions(definitions: readonly AppConfigDefinition[]): void {
  rootContainer.resolve(AppConfigRegistry).register(definitions)
}

/**
 * Registers dynamic app config patterns in the root DI container.
 */
export function registerAppConfigPatterns(definitions: readonly AppConfigPatternDefinition[]): void {
  rootContainer.resolve(AppConfigRegistry).registerPatterns(definitions)
}

function appConfigPatternMatches(definition: AppConfigPatternDefinition, key: string): boolean {
  definition.keyPattern.lastIndex = 0
  return definition.keyPattern.test(key)
}

/** Root dynamic app config registry instance. */
export const appConfigRegistry = rootContainer.resolve(AppConfigRegistry)

/** Root dynamic app config service instance. */
export const appConfigService = rootContainer.resolve(AppConfigService)
