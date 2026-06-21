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
    /** Debounce window: the ambient wake slides forward by this much on each new message, so a burst of chatter collapses into one recognizer look. */
    batchWindowMs?: number
    /** Upper bound on how long the debounce can keep sliding, anchored at the oldest unprocessed message — a never-quiet room still gets looked at within this. */
    hardCapMs?: number
  }
  generation?: {
    /** Hard ceiling on agent turns (LLM call + tool round) in one run, a backstop against an agent that loops without finishing. */
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
    /** Most-recent history (in tokens) kept verbatim below the compaction cut; older turns get summarized. */
    keepRecentTokens?: number
    /** How many times to re-compact when the provider still reports context overflow after a pass. */
    maxOverflowRetries?: number
    /** Headroom (in tokens) left free under the model's window so a compacted context still has room to generate. */
    reserveTokens?: number
    /** Render-time microcompact: clear old re-derivable tool results before full compaction. */
    microcompactEnabled?: boolean
    /** Number of most-recent compactable tool results to keep in full. */
    microcompactKeepRecent?: number
  }
  dailyReset?: {
    /** Whether each conversation rolls over to a fresh one once per day (clears accumulated context). */
    enabled?: boolean
    /** Local wall-clock time the daily reset fires, `HH:MM`. */
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

// The installation-wide runtime policy, stored as one app-config row under this
// key and overlaid on top of the per-agent model config. Persisted encrypted at
// rest (consistent with the other ai-agent app-config rows).
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

/**
 * Loads the full runtime profile for one agent: its three resolved model roles
 * (read from the agent's own metadata) merged with the installation-wide policy
 * (timeouts, ambient/compression/parallelism knobs read from app config).
 *
 * Throws when the agent is missing or not active, or has no `primary` model
 * configured — there is no global model fallback, so an unconfigured agent cannot
 * run rather than silently using someone else's model.
 */
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

/**
 * Resolves a runtime profile from explicit models + policy (no DB lookup), so
 * tests and callers that already hold the config can build a profile directly.
 * The three model roles resolve in parallel; the policy is filled with defaults.
 */
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

/**
 * Materializes the three model roles from config. Only `primary` is required;
 * `light` and `heavy` inherit primary's provider/model when omitted and differ
 * only in their reasoning floor — light reasons less (cheap, fast paths like the
 * ambient recognizer), heavy reasons more (hard work). The defaults (medium /
 * low / high) apply only when a role does not set `reasoning` itself.
 */
export function resolveAiAgentModelsConfig(config: AiAgentModelsConfig): ResolvedAiAgentModelsConfig {
  const parsed = AiAgentModelsConfigSchema.parse(config)
  const primary = withDefaultReasoning(parsed.primary, 'medium')
  // When a role is omitted, reuse primary's provider/model but pin the role's
  // reasoning floor outright (not via withDefaultReasoning) — an inherited role
  // ignores primary's own reasoning so light stays cheap and heavy stays deep.
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

/**
 * Validates a models config before it is saved: resolves the roles, then checks
 * every provider/model reference actually exists with the provider service.
 * Throws on the first bad reference so a config that names a non-existent model
 * never reaches storage.
 */
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

/** Reads `ai_agent.models` out of an agent's metadata blob. Returns undefined (not an error) when no primary model is set, so callers can treat "unconfigured" distinctly. */
export function readAiAgentModelsConfig(metadata: JsonObject): AiAgentModelsConfig | undefined {
  const aiAgent = jsonObject(metadata.ai_agent)
  const models = jsonObject(aiAgent?.models)
  if (!models?.primary) return undefined

  return AiAgentModelsConfigSchema.parse(models)
}

/**
 * Writes the models config back into the metadata blob, returning a new object.
 * Clones and merges rather than overwriting so sibling metadata (chat-channel
 * adapters, owner, other `ai_agent.*` keys) is preserved — the config screen only
 * owns the `models` sub-key, not the whole blob.
 */
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

// Fills every policy knob with its default so the rest of the runtime reads a
// fully-resolved profile and never has to repeat `?? default`. The literals here
// are the floor; each is overridable through the `ai_agent.runtime` app config.
// See the field docs on AiAgentRuntimePolicyConfig for what each one governs.
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
