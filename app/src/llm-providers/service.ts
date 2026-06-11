import { aeadDecrypt, aeadEncrypt } from '@agentbull/bullx-native-addons'
import { DomainError } from '@/common/errors'
import {
  getModel,
  getModels,
  getProviders,
  type CacheRetention,
  type Model,
  type SimpleStreamOptions,
  type Transport
} from '@earendil-works/pi-ai'
import { mapValues, pickBy, ms } from '@pleisto/active-support'
import { eq, sql } from 'drizzle-orm'
import { z } from 'zod'
import { DB, jsonbParam } from '@/common/database'
import { Agents, LlmProviders, type JsonObject, type JsonValue } from '@/common/db-schema'
import { cloneJsonObject, isJsonObject, jsonObject } from '@/common/json'
import { appConfigJsonRecordSchema } from '@/config/json-value-schema'
import { getSecretKey, SecretKeyPurpose } from '@/common/kms'

const providerIdPattern = /^[a-z][a-z0-9_-]{0,62}$/
const DEFAULT_LLM_TIMEOUT_MS = ms('10m')
const secretHeaderNames = new Set([
  'authorization',
  'proxy-authorization',
  'x-api-key',
  'api-key',
  'apikey',
  'openai-api-key',
  'anthropic-api-key'
])

export type LlmProviderRecord = typeof LlmProviders.$inferSelect

export interface LlmProviderProjection {
  providerId: string
  piProvider: string
  baseUrl: string | null
  providerOptions: JsonObject
  apiKey: {
    present: boolean
    masked: string | null
  }
  createdAt: Date
  updatedAt: Date
}

export interface LlmProviderModelProjection {
  id: string
  name: string
  api: string
  providerId: string
  piProvider: string
  contextWindow: number
  maxTokens: number
  reasoning: boolean
  input: Array<'text' | 'image'>
}

export interface LlmProviderResolvedModelRef {
  providerId: string
  model: string
  reasoning?: 'off' | 'minimal' | 'low' | 'medium' | 'high' | 'xhigh'
  temperature?: number
  maxTokens?: number
  cacheRetention?: CacheRetention
  transport?: Transport
}

export interface ResolvedLlmProviderModelProfile {
  config: LlmProviderResolvedModelRef & {
    piProvider: string
  }
  model: Model<any>
  options: SimpleStreamOptions
}

export interface LlmProviderApiAccess {
  providerId: string
  piProvider: string
  baseUrl: string | null
  apiKey: string
  providerOptions: NormalizedLlmProviderOptions
}

export type NormalizedLlmProviderOptions = JsonObject & {
  headers?: Record<string, string>
  timeoutMs?: number
  websocketConnectTimeoutMs?: number
  maxRetries?: number
  maxRetryDelayMs?: number
  transport?: Transport
  compat?: JsonObject
}

const JsonObjectSchema = z.custom<JsonObject>(value => isJsonObject(value))

export const LlmProviderIdSchema = z.string().regex(providerIdPattern, `providerId must match ${providerIdPattern}`)

export const LlmProviderOptionsSchema = z
  .object({
    headers: z.record(z.string(), z.string()).optional(),
    timeoutMs: z.number().int().positive().optional(),
    websocketConnectTimeoutMs: z.number().int().positive().optional(),
    maxRetries: z.number().int().nonnegative().optional(),
    maxRetryDelayMs: z.number().int().nonnegative().optional(),
    transport: z.enum(['sse', 'websocket', 'websocket-cached', 'auto']).optional(),
    compat: JsonObjectSchema.optional()
  })
  .strict()
  .default({})

export const LlmProviderCreateInputSchema = z
  .object({
    providerId: LlmProviderIdSchema,
    piProvider: z.string().min(1),
    baseUrl: z.string().nullable().optional(),
    apiKey: z.string().nullable().optional(),
    providerOptions: LlmProviderOptionsSchema.optional()
  })
  .strict()

export const LlmProviderUpdateInputSchema = z
  .object({
    providerId: LlmProviderIdSchema,
    piProvider: z.string().min(1).optional(),
    baseUrl: z.string().nullable().optional(),
    apiKey: z.string().nullable().optional(),
    providerOptions: LlmProviderOptionsSchema.optional()
  })
  .strict()

export const LlmProviderCheckInputSchema = z
  .object({
    providerId: LlmProviderIdSchema.optional(),
    piProvider: z.string().min(1).optional(),
    model: z.string().min(1).optional(),
    baseUrl: z.string().nullable().optional(),
    apiKey: z.string().nullable().optional(),
    providerOptions: LlmProviderOptionsSchema.optional()
  })
  .strict()

export type LlmProviderCreateInput = z.infer<typeof LlmProviderCreateInputSchema>

/**
 * Route-layer request body for creating an LLM provider (shared by setup and
 * console routes). Deep option validation stays in the service schemas.
 */
export const llmProviderCreateBody = z.object({
  providerId: z.string().min(1),
  piProvider: z.string().min(1),
  baseUrl: z.string().nullable().optional(),
  apiKey: z.string().nullable().optional(),
  providerOptions: (appConfigJsonRecordSchema as z.ZodType<JsonObject>).optional()
})
export type LlmProviderUpdateInput = z.infer<typeof LlmProviderUpdateInputSchema>
export type LlmProviderCheckInput = z.infer<typeof LlmProviderCheckInputSchema>

export async function listLlmProviders(): Promise<LlmProviderProjection[]> {
  const rows = await DB.select().from(LlmProviders).orderBy(LlmProviders.createdAt)
  return rows.map(projectLlmProvider)
}

export async function getLlmProvider(providerId: string): Promise<LlmProviderProjection> {
  return projectLlmProvider(await requireLlmProviderRow(providerId))
}

export async function upsertLlmProvider(input: LlmProviderCreateInput | LlmProviderUpdateInput) {
  const parsed = LlmProviderUpdateInputSchema.parse(input)
  const existing = await getLlmProviderRow(parsed.providerId)
  const piProvider = parsed.piProvider ?? existing?.piProvider
  if (!piProvider) throw new DomainError(422, 'piProvider is required')
  assertKnownPiProvider(piProvider)

  const providerOptions =
    parsed.providerOptions !== undefined
      ? normalizeProviderOptions(parsed.providerOptions)
      : cloneJsonObject(existing?.providerOptions ?? {})
  const baseUrl = Object.hasOwn(parsed, 'baseUrl') ? normalizeBaseUrl(parsed.baseUrl) : (existing?.baseUrl ?? null)
  const encryptedApiKey = resolveEncryptedApiKey(parsed, existing)

  const [row] = await DB.insert(LlmProviders)
    .values({
      providerId: parsed.providerId,
      piProvider,
      baseUrl,
      encryptedApiKey,
      providerOptions: jsonbParam(providerOptions)
    })
    .onConflictDoUpdate({
      target: LlmProviders.providerId,
      set: {
        piProvider,
        baseUrl,
        encryptedApiKey,
        providerOptions: jsonbParam(providerOptions),
        updatedAt: sql`now()`
      }
    })
    .returning()

  return projectLlmProvider(row!)
}

export async function createLlmProvider(input: LlmProviderCreateInput): Promise<LlmProviderProjection> {
  const parsed = LlmProviderCreateInputSchema.parse(input)
  if (await getLlmProviderRow(parsed.providerId)) throw new DomainError(409, 'llm provider already exists')
  return upsertLlmProvider(parsed)
}

export async function updateLlmProvider(input: LlmProviderUpdateInput): Promise<LlmProviderProjection> {
  const parsed = LlmProviderUpdateInputSchema.parse(input)
  await requireLlmProviderRow(parsed.providerId)
  return upsertLlmProvider(parsed)
}

export async function deleteLlmProvider(providerId: string): Promise<void> {
  const normalizedProviderId = LlmProviderIdSchema.parse(providerId)
  await requireLlmProviderRow(normalizedProviderId)

  const references = await listAgentModelReferences(normalizedProviderId)
  if (references.length > 0) {
    throw new DomainError(409, `llm provider is used by agent models: ${references.join(', ')}`)
  }

  await DB.delete(LlmProviders).where(eq(LlmProviders.providerId, normalizedProviderId))
}

export async function saveLlmProviders(inputs: readonly LlmProviderCreateInput[]): Promise<LlmProviderProjection[]> {
  const projections: LlmProviderProjection[] = []
  for (const input of inputs) projections.push(await upsertLlmProvider(LlmProviderCreateInputSchema.parse(input)))
  return projections
}

export async function checkLlmProvider(input: LlmProviderCheckInput): Promise<{
  ok: true
  provider: Omit<LlmProviderProjection, 'createdAt' | 'updatedAt'>
  model?: LlmProviderModelProjection
}> {
  const parsed = LlmProviderCheckInputSchema.parse(input)
  const existing = parsed.providerId ? await getLlmProviderRow(parsed.providerId) : undefined
  const providerId = parsed.providerId ?? existing?.providerId ?? 'check'
  const piProvider = parsed.piProvider ?? existing?.piProvider
  if (!piProvider) throw new DomainError(422, 'piProvider is required')
  assertKnownPiProvider(piProvider)

  const providerOptions =
    parsed.providerOptions !== undefined
      ? normalizeProviderOptions(parsed.providerOptions)
      : cloneJsonObject(existing?.providerOptions ?? {})
  const baseUrl = Object.hasOwn(parsed, 'baseUrl') ? normalizeBaseUrl(parsed.baseUrl) : (existing?.baseUrl ?? null)
  const apiKey = checkInputApiKey(parsed, existing)
  if (!apiKey) throw new DomainError(422, `llm provider api key is not configured: ${providerId}`)

  const model = parsed.model
    ? projectModel(providerId, piProvider, requirePiModel(piProvider, parsed.model))
    : undefined
  return {
    ok: true,
    provider: {
      providerId,
      piProvider,
      baseUrl,
      providerOptions,
      apiKey: {
        present: true,
        masked: maskApiKey()
      }
    },
    model
  }
}

export async function listLlmProviderModels(providerId: string): Promise<LlmProviderModelProjection[]> {
  const row = await requireLlmProviderRow(providerId)
  return getModels(row.piProvider as never).map(model => projectModel(row.providerId, row.piProvider, model))
}

export function listPiLlmProviders(): Array<{ id: string; modelCount: number }> {
  return getProviders().map(id => ({
    id,
    modelCount: getModels(id as never).length
  }))
}

export async function assertLlmProviderModelReference(input: { providerId: string; model: string }): Promise<void> {
  const row = await requireLlmProviderRow(input.providerId)
  requirePiModel(row.piProvider, input.model)
}

export async function resolveLlmProviderModelProfile(
  ref: LlmProviderResolvedModelRef
): Promise<ResolvedLlmProviderModelProfile> {
  const row = await requireLlmProviderRow(ref.providerId)
  const apiKey = decryptApiKey(row)
  if (!apiKey) throw new DomainError(422, `llm provider api key is not configured: ${row.providerId}`)

  const providerOptions = normalizeProviderOptions(row.providerOptions)
  const model = clonePiModelWithProviderOverrides(requirePiModel(row.piProvider, ref.model), row, providerOptions)

  return {
    config: {
      providerId: row.providerId,
      piProvider: row.piProvider,
      model: ref.model,
      reasoning: ref.reasoning,
      temperature: ref.temperature,
      maxTokens: ref.maxTokens,
      cacheRetention: ref.cacheRetention,
      transport: ref.transport
    },
    model,
    options: {
      apiKey,
      timeoutMs: providerOptions.timeoutMs ?? DEFAULT_LLM_TIMEOUT_MS,
      websocketConnectTimeoutMs: providerOptions.websocketConnectTimeoutMs,
      maxRetries: providerOptions.maxRetries,
      maxRetryDelayMs: providerOptions.maxRetryDelayMs,
      transport: ref.transport ?? providerOptions.transport,
      cacheRetention: ref.cacheRetention,
      maxTokens: ref.maxTokens,
      reasoning: ref.reasoning === 'off' ? undefined : ref.reasoning,
      temperature: ref.temperature
    }
  }
}

export async function resolveLlmProviderApiAccess(providerId: string): Promise<LlmProviderApiAccess> {
  const row = await requireLlmProviderRow(providerId)
  const apiKey = decryptApiKey(row)
  if (!apiKey) throw new DomainError(422, `llm provider api key is not configured: ${row.providerId}`)

  return {
    providerId: row.providerId,
    piProvider: row.piProvider,
    baseUrl: row.baseUrl,
    apiKey,
    providerOptions: normalizeProviderOptions(row.providerOptions)
  }
}

function projectLlmProvider(row: LlmProviderRecord): LlmProviderProjection {
  return {
    providerId: row.providerId,
    piProvider: row.piProvider,
    baseUrl: row.baseUrl,
    providerOptions: cloneJsonObject(row.providerOptions),
    apiKey: {
      present: Boolean(row.encryptedApiKey),
      masked: row.encryptedApiKey ? maskApiKey() : null
    },
    createdAt: row.createdAt,
    updatedAt: row.updatedAt
  }
}

function projectModel(providerId: string, piProvider: string, model: Model<any>): LlmProviderModelProjection {
  return {
    id: model.id,
    name: model.name,
    api: model.api,
    providerId,
    piProvider,
    contextWindow: model.contextWindow,
    maxTokens: model.maxTokens,
    reasoning: model.reasoning,
    input: [...model.input]
  }
}

async function getLlmProviderRow(providerId: string): Promise<LlmProviderRecord | undefined> {
  const normalizedProviderId = LlmProviderIdSchema.parse(providerId)
  const [row] = await DB.select().from(LlmProviders).where(eq(LlmProviders.providerId, normalizedProviderId)).limit(1)
  return row
}

async function requireLlmProviderRow(providerId: string): Promise<LlmProviderRecord> {
  const row = await getLlmProviderRow(providerId)
  if (!row) throw new DomainError(404, `llm provider not found: ${providerId}`)
  return row
}

function assertKnownPiProvider(piProvider: string): void {
  if (!getProviders().includes(piProvider as never)) {
    throw new DomainError(422, `unknown Pi provider: ${piProvider}`)
  }
}

function requirePiModel(piProvider: string, modelId: string): Model<any> {
  const model = getModel(piProvider as never, modelId as never) as Model<any> | undefined
  if (!model) throw new DomainError(422, `unknown Pi model: ${piProvider}/${modelId}`)
  return model
}

function normalizeProviderOptions(value: unknown): NormalizedLlmProviderOptions {
  const parsed = LlmProviderOptionsSchema.parse(value ?? {})
  if (parsed.headers) assertNonSecretHeaders(parsed.headers)
  return stripUndefined(parsed) as NormalizedLlmProviderOptions
}

function assertNonSecretHeaders(headers: Record<string, string>): void {
  for (const name of Object.keys(headers)) {
    if (secretHeaderNames.has(name.trim().toLowerCase())) {
      throw new DomainError(422, `providerOptions.headers.${name} must not contain secret credentials`)
    }
  }
}

function normalizeBaseUrl(value: string | null | undefined): string | null {
  if (value === undefined || value === null) return null
  const trimmed = value.trim()
  if (!trimmed) return null

  let url: URL
  try {
    url = new URL(trimmed)
  } catch {
    throw new DomainError(422, 'baseUrl must be a valid URL')
  }
  if (url.protocol !== 'http:' && url.protocol !== 'https:') {
    throw new DomainError(422, 'baseUrl must use http or https')
  }
  return trimmed
}

function resolveEncryptedApiKey(
  input: Pick<LlmProviderUpdateInput, 'providerId' | 'apiKey'>,
  existing: LlmProviderRecord | undefined
): string | null {
  if (!Object.hasOwn(input, 'apiKey')) return existing?.encryptedApiKey ?? null

  const apiKey = normalizeApiKey(input.apiKey)
  if (!apiKey) return null
  return encryptApiKey(input.providerId, apiKey)
}

function checkInputApiKey(input: LlmProviderCheckInput, existing: LlmProviderRecord | undefined): string | undefined {
  if (Object.hasOwn(input, 'apiKey')) return normalizeApiKey(input.apiKey) ?? undefined
  return existing ? (decryptApiKey(existing) ?? undefined) : undefined
}

function normalizeApiKey(value: string | null | undefined): string | null {
  if (value === undefined || value === null) return null
  const trimmed = value.trim()
  return trimmed ? trimmed : null
}

function encryptApiKey(providerId: string, apiKey: string): string {
  return aeadEncrypt(apiKey, apiKeyEncryptionKey(providerId))
}

function decryptApiKey(row: LlmProviderRecord): string | null {
  if (!row.encryptedApiKey) return null
  try {
    return aeadDecrypt(row.encryptedApiKey, apiKeyEncryptionKey(row.providerId)).toString('utf-8')
  } catch (error) {
    throw new DomainError(
      422,
      `failed to decrypt llm provider api key: ${row.providerId}${error instanceof Error ? ` (${error.message})` : ''}`
    )
  }
}

function apiKeyEncryptionKey(providerId: string): string {
  return getSecretKey(SecretKeyPurpose.DATABASE_ENCRYPTION, `llm_providers:${providerId}:api_key`)
}

function clonePiModelWithProviderOverrides(
  model: Model<any>,
  row: LlmProviderRecord,
  providerOptions: NormalizedLlmProviderOptions
): Model<any> {
  const headers = providerOptions.headers ? { ...model.headers, ...providerOptions.headers } : model.headers
  const compat = providerOptions.compat
    ? ({ ...(model.compat as JsonObject | undefined), ...providerOptions.compat } as Model<any>['compat'])
    : model.compat

  return {
    ...model,
    baseUrl: row.baseUrl ?? model.baseUrl,
    headers,
    compat
  }
}

async function listAgentModelReferences(providerId: string): Promise<string[]> {
  const agents = await DB.select({ uid: Agents.uid, metadata: Agents.metadata }).from(Agents)
  const references: string[] = []

  for (const agent of agents) {
    const models = jsonObject(jsonObject(agent.metadata.ai_agent)?.models)
    if (!models) continue

    for (const profile of ['primary', 'light', 'heavy'] as const) {
      const model = jsonObject(models[profile])
      if (model?.providerId === providerId) references.push(`${agent.uid}:${profile}`)
    }
  }

  return references
}

function maskApiKey(): string {
  return '********'
}

function stripUndefined(value: unknown): JsonValue {
  if (Array.isArray(value)) return value.map(item => stripUndefined(item))
  if (isJsonObject(value)) {
    return mapValues(
      pickBy(value, item => item !== undefined),
      item => stripUndefined(item)
    ) as JsonObject
  }
  if (typeof value === 'string' || typeof value === 'number' || typeof value === 'boolean' || value === null) {
    return value
  }
  return null
}
