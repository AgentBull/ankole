import { type CacheRetention, type Model, type SimpleStreamOptions } from '@/llm'
import { ms } from '@pleisto/active-support'
import { z } from 'zod'
import { defineAppConfig, registerAppConfigDefinitions, appConfigService } from '@/config/app-configure'
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
  generation?: {
    maxTurns?: number
    /**
     * Abort (and retry) a run after this long with no agent events (stream
     * progress, tool activity). Defaults to OpenAI's own request-timeout ceiling
     * — see {@link defaultGenerationStallTimeoutMs}. Long-running silent tools
     * must fit this budget too; clarify waits are exempt.
     */
    stallTimeoutMs?: number
    /**
     * Silence budget between content chunks once a call is streaming. Providers
     * chunk continuously (reasoning included), so mid-stream silence is a dead
     * pipe — this can be far tighter than `stallTimeoutMs`.
     */
    streamGapTimeoutMs?: number
    /** Automatic re-runs after a stall abort or transient provider failure. */
    maxTransientRetries?: number
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
  }
  parallelism?: {
    /** Bound on concurrently executing conversations per agent (1 = serial). */
    maxConversationsPerAgent?: number
  }
}

export interface ResolvedAiAgentModelProfile {
  config: LlmProviderResolvedModelRef & {
    llmProvider: string
  }
  model: Model<any>
  options: SimpleStreamOptions
  profile: AiAgentModelProfileName
}

export interface AiAgentRuntimeProfile {
  ambient: Required<NonNullable<AiAgentRuntimePolicyConfig['ambient']>>
  compression: Required<NonNullable<AiAgentRuntimePolicyConfig['compression']>>
  dailyReset: Required<NonNullable<AiAgentRuntimePolicyConfig['dailyReset']>>
  generation: Required<NonNullable<AiAgentRuntimePolicyConfig['generation']>>
  parallelism: Required<NonNullable<AiAgentRuntimePolicyConfig['parallelism']>>
  heavyModel: ResolvedAiAgentModelProfile
  lightModel: ResolvedAiAgentModelProfile
  primaryModel: ResolvedAiAgentModelProfile
}

const ReasoningSchema = z.enum(['off', 'minimal', 'low', 'medium', 'high', 'xhigh'])
const CacheRetentionSchema = z.enum(['none', 'short', 'long'])

export const AiAgentModelProfileConfigSchema = z
  .object({
    providerId: z.string().min(1),
    model: z.string().min(1),
    temperature: z.number().finite().optional(),
    maxTokens: z.number().int().positive().optional(),
    reasoning: ReasoningSchema.optional(),
    cacheRetention: CacheRetentionSchema.optional()
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
    generation: z
      .object({
        maxTurns: z.number().int().positive().optional(),
        stallTimeoutMs: z.number().int().positive().optional(),
        streamGapTimeoutMs: z.number().int().positive().optional(),
        maxTransientRetries: z.number().int().nonnegative().optional()
      })
      .optional(),
    dailyReset: z
      .object({
        enabled: z.boolean().optional(),
        hour: z
          .string()
          .regex(/^\d{2}:\d{2}$/)
          .optional()
      })
      .optional(),
    parallelism: z
      .object({
        maxConversationsPerAgent: z.number().int().min(1).max(128).optional()
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

/**
 * Default bound on concurrently executing conversations per agent. Chat loads
 * are IO-dominated, so 16 in-flight LLM turns fit a 4-core baseline; set the
 * config to 1 to restore strictly serial delivery.
 */
export const DEFAULT_MAX_CONVERSATIONS_PER_AGENT = 16

/** Installation-wide delivery parallelism knobs (cheap read; values are cached by app config). */
export async function loadAiAgentParallelismConfig(): Promise<{ maxConversationsPerAgent: number }> {
  const runtimeConfigValue = await appConfigService.get(AiAgentRuntimeConfigDefinition)
  const runtimeConfig = AiAgentRuntimeConfigSchema.parse(runtimeConfigValue ?? {})
  return {
    maxConversationsPerAgent: runtimeConfig.parallelism?.maxConversationsPerAgent ?? DEFAULT_MAX_CONVERSATIONS_PER_AGENT
  }
}

export async function loadAiAgentRuntimeProfile(agentUid: string): Promise<AiAgentRuntimeProfile> {
  const [agentResult, runtimeConfigValue] = await Promise.all([
    getAgent(agentUid),
    appConfigService.get(AiAgentRuntimeConfigDefinition)
  ])
  if (!agentResult || agentResult.principal.status !== 'active') {
    throw new AiAgentConfigError(`agent not found: ${agentUid}`)
  }

  const runtimeConfig = AiAgentRuntimeConfigSchema.parse(runtimeConfigValue ?? {})
  const models = readAiAgentModelsConfig(agentResult.agent.metadata)
  if (models) return resolveAiAgentRuntimeProfile({ models, policy: runtimeConfig })

  throw new AiAgentConfigError(`agents.metadata.ai_agent.models.primary is not configured for ${agentUid}`)
}

export async function resolveAiAgentRuntimeProfile(input: {
  models: AiAgentModelsConfig
  policy?: AiAgentRuntimePolicyConfig
}): Promise<AiAgentRuntimeProfile> {
  const models = resolveAiAgentModelsConfig(input.models)
  const [primaryModel, lightModel, heavyModel] = await Promise.all([
    resolveModelProfile('primary', models.primary),
    resolveModelProfile('light', models.light),
    resolveModelProfile('heavy', models.heavy)
  ])
  const policy = resolveAiAgentRuntimePolicy(input.policy ?? {})

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

/**
 * Default silence budget, anchored to the vendor's own request-timeout default:
 * the OpenAI SDK uses `DEFAULT_TIMEOUT = 600000` (10 minutes) as the longest it
 * waits for a response, and its guidance for anything longer is to switch to
 * streaming / background, not to wait more (OpenRouter publishes no figure and
 * keeps the pipe warm with `: OPENROUTER PROCESSING` comments). Since we stream,
 * a healthy reasoning model emits content deltas continuously (observed
 * silentForMs ≈ tens of ms), so the streaming phase is governed by the tighter
 * `streamGapTimeoutMs`; this budget only bounds pre-first-token silence and
 * silent tool execution. Ten minutes of *no progress at all* therefore already
 * matches OpenAI's whole-request ceiling — beyond it the run is treated as a
 * dead stream and retried. Per-deployment overrides ride `generation.stallTimeoutMs`.
 */
export function defaultGenerationStallTimeoutMs(): number {
  return ms('10m')
}

function resolveAiAgentRuntimePolicy(
  config: AiAgentRuntimePolicyConfig
): Pick<AiAgentRuntimeProfile, 'ambient' | 'compression' | 'dailyReset' | 'generation' | 'parallelism'> {
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
    generation: {
      maxTurns: config.generation?.maxTurns ?? 100,
      stallTimeoutMs: config.generation?.stallTimeoutMs ?? defaultGenerationStallTimeoutMs(),
      streamGapTimeoutMs: config.generation?.streamGapTimeoutMs ?? ms('5m'),
      maxTransientRetries: config.generation?.maxTransientRetries ?? 2
    },
    dailyReset: {
      enabled: config.dailyReset?.enabled ?? true,
      hour: config.dailyReset?.hour ?? '04:00'
    },
    parallelism: {
      maxConversationsPerAgent: config.parallelism?.maxConversationsPerAgent ?? DEFAULT_MAX_CONVERSATIONS_PER_AGENT
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
