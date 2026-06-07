import {
  getModel,
  type CacheRetention,
  type Model,
  type SimpleStreamOptions,
  type Transport
} from '@earendil-works/pi-ai'
import { z } from 'zod'
import { defineAppConfig, registerAppConfigDefinitions, appConfigService } from '@/config/app-configure'
import type { ConfigureJsonValue } from '@/common/db-schema/app-configure'
import type { JsonObject, JsonValue } from '@/common/db-schema'
import { getAgent } from '@/principals/agents/service'
import {
  assertLlmProviderModelReference,
  resolveLlmProviderModelProfile,
  type LlmProviderResolvedModelRef
} from '@/llm-providers/service'

export type AiAgentReasoning = 'off' | 'minimal' | 'low' | 'medium' | 'high' | 'xhigh'
export type AiAgentModelProfileName = 'primary' | 'light' | 'heavy'

export interface AiAgentModelProfileConfig {
  cacheRetention?: CacheRetention
  maxTokens?: number
  model: string
  providerId: string
  reasoning?: AiAgentReasoning
  temperature?: number
  transport?: Transport
}

export interface AiAgentModelsConfig {
  heavy?: AiAgentModelProfileConfig
  light?: AiAgentModelProfileConfig
  primary: AiAgentModelProfileConfig
}

export interface ResolvedAiAgentModelsConfig {
  heavy: AiAgentModelProfileConfig & { reasoning: AiAgentReasoning }
  light: AiAgentModelProfileConfig & { reasoning: AiAgentReasoning }
  primary: AiAgentModelProfileConfig & { reasoning: AiAgentReasoning }
}

export interface AiAgentRuntimePolicyConfig {
  ambient?: {
    batchWindowMs?: number
    freshnessMs?: number
  }
  compression?: {
    enabled?: boolean
    keepRecentTokens?: number
    maxOverflowRetries?: number
    reserveTokens?: number
  }
  dailyReset?: {
    enabled?: boolean
    hour?: string
    retryMinutes?: number
    timezone?: string
  }
}

export interface AiAgentLegacyModelProfileConfig {
  apiKey?: string
  cacheRetention?: CacheRetention
  maxTokens?: number
  model: string
  provider: string
  reasoning?: AiAgentReasoning
  temperature?: number
  transport?: Transport
}

export interface AiAgentConfig extends AiAgentRuntimePolicyConfig {
  heavy_model?: AiAgentLegacyModelProfileConfig
  light_model?: AiAgentLegacyModelProfileConfig
  primary_model?: AiAgentLegacyModelProfileConfig
}

export interface AiAgentLegacyRuntimeConfig extends AiAgentRuntimePolicyConfig {
  heavy_model?: AiAgentLegacyModelProfileConfig
  light_model?: AiAgentLegacyModelProfileConfig
  primary_model: AiAgentLegacyModelProfileConfig
}

export interface ResolvedAiAgentModelProfile {
  config: LlmProviderResolvedModelRef & {
    piProvider: string
  }
  model: Model<any>
  options: SimpleStreamOptions
  profile: AiAgentModelProfileName
}

export interface AiAgentRuntimeProfile {
  ambient: Required<NonNullable<AiAgentRuntimePolicyConfig['ambient']>>
  compression: Required<NonNullable<AiAgentRuntimePolicyConfig['compression']>>
  dailyReset: Required<NonNullable<AiAgentRuntimePolicyConfig['dailyReset']>>
  heavyModel: ResolvedAiAgentModelProfile
  lightModel: ResolvedAiAgentModelProfile
  primaryModel: ResolvedAiAgentModelProfile
}

const ReasoningSchema = z.enum(['off', 'minimal', 'low', 'medium', 'high', 'xhigh'])
const CacheRetentionSchema = z.enum(['none', 'short', 'long'])
const TransportSchema = z.enum(['sse', 'websocket', 'websocket-cached', 'auto'])

export const AiAgentModelProfileConfigSchema = z
  .object({
    providerId: z.string().min(1),
    model: z.string().min(1),
    temperature: z.number().finite().optional(),
    maxTokens: z.number().int().positive().optional(),
    reasoning: ReasoningSchema.optional(),
    cacheRetention: CacheRetentionSchema.optional(),
    transport: TransportSchema.optional()
  })
  .strict()

export const AiAgentModelsConfigSchema = z
  .object({
    primary: AiAgentModelProfileConfigSchema,
    light: AiAgentModelProfileConfigSchema.optional(),
    heavy: AiAgentModelProfileConfigSchema.optional()
  })
  .strict()

const AiAgentLegacyModelProfileConfigSchema = z
  .object({
    provider: z.string().min(1),
    model: z.string().min(1),
    apiKey: z.string().min(1).optional(),
    temperature: z.number().finite().optional(),
    maxTokens: z.number().int().positive().optional(),
    reasoning: ReasoningSchema.optional(),
    cacheRetention: CacheRetentionSchema.optional(),
    transport: TransportSchema.optional()
  })
  .strict()

const AiAgentRuntimePolicyConfigSchema = z
  .object({
    compression: z
      .object({
        enabled: z.boolean().optional(),
        reserveTokens: z.number().int().positive().optional(),
        keepRecentTokens: z.number().int().positive().optional(),
        maxOverflowRetries: z.number().int().nonnegative().optional()
      })
      .optional(),
    ambient: z
      .object({
        batchWindowMs: z.number().int().positive().optional(),
        freshnessMs: z.number().int().positive().optional()
      })
      .optional(),
    dailyReset: z
      .object({
        enabled: z.boolean().optional(),
        timezone: z.string().min(1).optional(),
        hour: z
          .string()
          .regex(/^\d{2}:\d{2}$/)
          .optional(),
        retryMinutes: z.number().int().positive().optional()
      })
      .optional()
  })
  .strict()

const AiAgentRuntimeConfigSchema = AiAgentRuntimePolicyConfigSchema.extend({
  primary_model: AiAgentLegacyModelProfileConfigSchema.optional(),
  light_model: AiAgentLegacyModelProfileConfigSchema.optional(),
  heavy_model: AiAgentLegacyModelProfileConfigSchema.optional()
})

export const AiAgentRuntimeConfigDefinition = defineAppConfig<ConfigureJsonValue>({
  key: 'ai_agent.runtime',
  description: 'AIAgent runtime session policy; legacy model fields are read-only compatibility input',
  encrypted: true,
  schema: AiAgentRuntimeConfigSchema as unknown as z.ZodType<ConfigureJsonValue>
})

registerAppConfigDefinitions([AiAgentRuntimeConfigDefinition])

export async function loadAiAgentRuntimeProfile(agentUid: string): Promise<AiAgentRuntimeProfile> {
  const [agentResult, runtimeConfigValue] = await Promise.all([
    getAgent(agentUid),
    appConfigService.get(AiAgentRuntimeConfigDefinition)
  ])
  if (!agentResult || agentResult.principal.status !== 'active') {
    throw new AiAgentConfigError(`agent not found: ${agentUid}`)
  }

  const runtimeConfig = AiAgentRuntimeConfigSchema.parse(runtimeConfigValue ?? {})
  const policy = resolveAiAgentRuntimePolicy(runtimeConfig)
  const models = readAiAgentModelsConfig(agentResult.agent.metadata)
  if (models) return resolveAiAgentRuntimeProfile({ models, policy })

  if (runtimeConfig.primary_model) {
    return resolveLegacyAiAgentRuntimeProfile({
      ...runtimeConfig,
      primary_model: runtimeConfig.primary_model
    })
  }

  throw new AiAgentConfigError(`agents.metadata.ai_agent.models.primary is not configured for ${agentUid}`)
}

export async function resolveAiAgentRuntimeProfile(input: {
  models: AiAgentModelsConfig
  policy?: AiAgentRuntimePolicyConfig
}): Promise<AiAgentRuntimeProfile> {
  const models = resolveAiAgentModelsConfig(input.models)
  const policy = resolveAiAgentRuntimePolicy(input.policy ?? {})
  const [primaryModel, lightModel, heavyModel] = await Promise.all([
    resolveModelProfile('primary', models.primary),
    resolveModelProfile('light', models.light),
    resolveModelProfile('heavy', models.heavy)
  ])

  return {
    primaryModel,
    lightModel,
    heavyModel,
    ...policy
  }
}

export function resolveAiAgentModelsConfig(config: AiAgentModelsConfig): ResolvedAiAgentModelsConfig {
  const parsed = AiAgentModelsConfigSchema.parse(config)
  const primary = withDefaultReasoning(parsed.primary, 'medium')
  const light = parsed.light ? withDefaultReasoning(parsed.light, 'low') : { ...parsed.primary, reasoning: 'low' as const }
  const heavy = parsed.heavy
    ? withDefaultReasoning(parsed.heavy, 'high')
    : { ...parsed.primary, reasoning: 'high' as const }

  return {
    primary,
    light,
    heavy
  }
}

export async function validateAiAgentModelsConfig(config: AiAgentModelsConfig): Promise<void> {
  const models = resolveAiAgentModelsConfig(config)
  await Promise.all(
    ([models.primary, models.light, models.heavy] as const).map(model =>
      assertLlmProviderModelReference({
        providerId: model.providerId,
        model: model.model
      })
    )
  )
}

export function readAiAgentModelsConfig(metadata: JsonObject): AiAgentModelsConfig | undefined {
  const aiAgent = jsonObject(metadata.ai_agent)
  const models = jsonObject(aiAgent?.models)
  if (!models?.primary) return undefined

  return AiAgentModelsConfigSchema.parse(models)
}

export function writeAiAgentModelsConfig(metadata: JsonObject, models: AiAgentModelsConfig): JsonObject {
  const parsed = AiAgentModelsConfigSchema.parse(models)
  const next = cloneJsonObject(metadata)
  const aiAgent = jsonObject(next.ai_agent) ? cloneJsonObject(next.ai_agent as JsonObject) : {}
  aiAgent.models = cloneJsonObject(parsed as unknown as JsonObject)
  next.ai_agent = aiAgent
  return next
}

export function resolveLegacyAiAgentRuntimeProfile(config: AiAgentLegacyRuntimeConfig): AiAgentRuntimeProfile {
  const parsed = AiAgentRuntimeConfigSchema.parse(config)
  if (!parsed.primary_model) throw new AiAgentConfigError('ai_agent.runtime primary_model is not configured')
  const primary = withDefaultLegacyReasoning(parsed.primary_model, 'medium')
  const light = parsed.light_model
    ? withDefaultLegacyReasoning(parsed.light_model, 'low')
    : { ...parsed.primary_model, reasoning: 'low' as const }
  const heavy = parsed.heavy_model
    ? withDefaultLegacyReasoning(parsed.heavy_model, 'high')
    : { ...parsed.primary_model, reasoning: 'high' as const }

  return {
    primaryModel: resolveLegacyModelProfile('primary', primary),
    lightModel: resolveLegacyModelProfile('light', light),
    heavyModel: resolveLegacyModelProfile('heavy', heavy),
    ...resolveAiAgentRuntimePolicy(parsed)
  }
}

function resolveAiAgentRuntimePolicy(config: AiAgentRuntimePolicyConfig): Pick<
  AiAgentRuntimeProfile,
  'ambient' | 'compression' | 'dailyReset'
> {
  return {
    compression: {
      enabled: config.compression?.enabled ?? true,
      reserveTokens: config.compression?.reserveTokens ?? 16384,
      keepRecentTokens: config.compression?.keepRecentTokens ?? 20000,
      maxOverflowRetries: config.compression?.maxOverflowRetries ?? 1
    },
    ambient: {
      batchWindowMs: config.ambient?.batchWindowMs ?? 1500,
      freshnessMs: config.ambient?.freshnessMs ?? 60000
    },
    dailyReset: {
      enabled: config.dailyReset?.enabled ?? true,
      timezone: config.dailyReset?.timezone ?? 'Etc/UTC',
      hour: config.dailyReset?.hour ?? '04:00',
      retryMinutes: config.dailyReset?.retryMinutes ?? 30
    }
  }
}

function withDefaultReasoning(
  config: AiAgentModelProfileConfig,
  reasoning: AiAgentReasoning
): AiAgentModelProfileConfig & { reasoning: AiAgentReasoning } {
  return {
    ...config,
    reasoning: config.reasoning ?? reasoning
  }
}

function withDefaultLegacyReasoning(
  config: AiAgentLegacyModelProfileConfig,
  reasoning: AiAgentReasoning
): AiAgentLegacyModelProfileConfig & { reasoning: AiAgentReasoning } {
  return {
    ...config,
    reasoning: config.reasoning ?? reasoning
  }
}

async function resolveModelProfile(
  profile: AiAgentModelProfileName,
  config: AiAgentModelProfileConfig & { reasoning: AiAgentReasoning }
): Promise<ResolvedAiAgentModelProfile> {
  const resolved = await resolveLlmProviderModelProfile(config)
  return {
    ...resolved,
    profile
  }
}

function resolveLegacyModelProfile(
  profile: AiAgentModelProfileName,
  config: AiAgentLegacyModelProfileConfig & { reasoning: AiAgentReasoning }
): ResolvedAiAgentModelProfile {
  const model = getModel(config.provider as never, config.model as never) as Model<any> | undefined
  if (!model) throw new AiAgentConfigError(`unknown Pi model: ${config.provider}/${config.model}`)
  if (!config.apiKey) throw new AiAgentConfigError(`legacy ai_agent.runtime apiKey is required for ${profile}`)

  return {
    profile,
    config: {
      providerId: config.provider,
      piProvider: config.provider,
      model: config.model,
      reasoning: config.reasoning,
      temperature: config.temperature,
      maxTokens: config.maxTokens,
      cacheRetention: config.cacheRetention,
      transport: config.transport
    },
    model,
    options: {
      apiKey: config.apiKey,
      cacheRetention: config.cacheRetention,
      maxTokens: config.maxTokens,
      reasoning: config.reasoning === 'off' ? undefined : config.reasoning,
      temperature: config.temperature,
      transport: config.transport
    }
  }
}

function cloneJsonObject(value: JsonObject): JsonObject {
  return structuredClone(value)
}

function jsonObject(value: JsonValue | undefined): JsonObject | undefined {
  return isJsonObject(value) ? value : undefined
}

function isJsonObject(value: unknown): value is JsonObject {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

export class AiAgentConfigError extends Error {
  constructor(message: string) {
    super(message)
    this.name = 'AiAgentConfigError'
  }
}
