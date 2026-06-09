import { type CacheRetention, type Model, type SimpleStreamOptions, type Transport } from '@earendil-works/pi-ai'
import { z } from 'zod'
import { defineAppConfig, registerAppConfigDefinitions, appConfigService } from '@/config/app-configure'
import { loadSystemTimezoneWithLegacyBackfill } from '@/config/system'
import type { ConfigureJsonValue } from '@/common/db-schema/app-configure'
import type { JsonObject } from '@/common/db-schema'
import { cloneJsonObject, jsonObject } from '@/common/json'
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
    hardCapMs?: number
  }
  compression?: {
    enabled?: boolean
    keepRecentTokens?: number
    maxOverflowRetries?: number
    reserveTokens?: number
    /** Render-time microcompact: clear old re-derivable tool results before full compaction. */
    microcompactEnabled?: boolean
    /** Number of most-recent compactable tool results to keep in full. */
    microcompactKeepRecent?: number
  }
  dailyReset?: {
    enabled?: boolean
    hour?: string
    timezone?: string
  }
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

const AiAgentRuntimePolicyConfigSchema = z
  .object({
    compression: z
      .object({
        enabled: z.boolean().optional(),
        reserveTokens: z.number().int().positive().optional(),
        keepRecentTokens: z.number().int().positive().optional(),
        maxOverflowRetries: z.number().int().nonnegative().optional(),
        microcompactEnabled: z.boolean().optional(),
        microcompactKeepRecent: z.number().int().nonnegative().optional()
      })
      .optional(),
    ambient: z
      .object({
        batchWindowMs: z.number().int().positive().optional(),
        hardCapMs: z.number().int().positive().optional()
      })
      .optional(),
    dailyReset: z
      .object({
        enabled: z.boolean().optional(),
        timezone: z.string().min(1).optional(),
        hour: z
          .string()
          .regex(/^\d{2}:\d{2}$/)
          .optional()
      })
      .optional()
  })
  .strict()

const AiAgentRuntimeConfigSchema = AiAgentRuntimePolicyConfigSchema

export const AiAgentRuntimeConfigDefinition = defineAppConfig<ConfigureJsonValue>({
  key: 'ai_agent.runtime',
  description: 'AIAgent runtime session policy',
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
  const policy = resolveAiAgentRuntimePolicy(
    runtimeConfig,
    await loadSystemTimezoneWithLegacyBackfill(runtimeConfig.dailyReset?.timezone)
  )
  const models = readAiAgentModelsConfig(agentResult.agent.metadata)
  if (models) return resolveAiAgentRuntimeProfile({ models, policy })

  throw new AiAgentConfigError(`agents.metadata.ai_agent.models.primary is not configured for ${agentUid}`)
}

export async function resolveAiAgentRuntimeProfile(input: {
  models: AiAgentModelsConfig
  policy?: AiAgentRuntimePolicyConfig
}): Promise<AiAgentRuntimeProfile> {
  const models = resolveAiAgentModelsConfig(input.models)
  const policy = resolveAiAgentRuntimePolicy(
    input.policy ?? {},
    await loadSystemTimezoneWithLegacyBackfill(input.policy?.dailyReset?.timezone)
  )
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
  const light = parsed.light
    ? withDefaultReasoning(parsed.light, 'low')
    : { ...parsed.primary, reasoning: 'low' as const }
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

function resolveAiAgentRuntimePolicy(
  config: AiAgentRuntimePolicyConfig,
  systemTimezone: string
): Pick<AiAgentRuntimeProfile, 'ambient' | 'compression' | 'dailyReset'> {
  return {
    compression: {
      enabled: config.compression?.enabled ?? true,
      reserveTokens: config.compression?.reserveTokens ?? 16384,
      keepRecentTokens: config.compression?.keepRecentTokens ?? 20000,
      maxOverflowRetries: config.compression?.maxOverflowRetries ?? 1,
      microcompactEnabled: config.compression?.microcompactEnabled ?? true,
      microcompactKeepRecent: config.compression?.microcompactKeepRecent ?? 6
    },
    ambient: {
      batchWindowMs: config.ambient?.batchWindowMs ?? 1500,
      hardCapMs: config.ambient?.hardCapMs ?? 60000
    },
    dailyReset: {
      enabled: config.dailyReset?.enabled ?? true,
      timezone: systemTimezone,
      hour: config.dailyReset?.hour ?? '04:00'
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

export class AiAgentConfigError extends Error {
  constructor(message: string) {
    super(message)
    this.name = 'AiAgentConfigError'
  }
}
