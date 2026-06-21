import { z } from 'zod'
import { defineAppConfig, registerAppConfigDefinitions } from '@/config/app-configure'
import type { ConfigureJsonValue } from '@/common/db-schema/app-configure'

export type ChatRecallEmbeddingProviderKind = 'openai' | 'openrouter' | 'vllm'
export type ChatRecallIndexStrategy = 'auto' | 'halfvec_hnsw' | 'binary_quantized_hnsw' | 'exact_only'

/**
 * Operator-supplied recall settings as they arrive from the console.
 *
 * Every field is optional because the console saves partial patches and the
 * stored value may predate fields added later. {@link normalizeChatRecallConfig}
 * fills the gaps with defaults so the rest of the module can rely on a complete
 * shape.
 */
export interface ChatRecallConfig {
  vector?: {
    enabled?: boolean
    providerKind?: ChatRecallEmbeddingProviderKind
    providerId?: string
    model?: string
    dimensions?: number
    batchSize?: number
    concurrency?: number
    indexStrategy?: ChatRecallIndexStrategy
  }
  rerank?: {
    limit?: number
    rrfK?: number
    recencyHalfLifeDays?: number
    mmrLambda?: number
  }
  worker?: {
    enabled?: boolean
    pollIntervalMs?: number
    maxAttempts?: number
  }
}

/**
 * Fully resolved recall settings with every default applied.
 *
 * This is the shape the runtime, worker, and search service actually read.
 * Provider/model fields under `vector` stay optional because recall can be
 * enabled in config before an embedding provider has been chosen.
 */
export interface NormalizedChatRecallConfig {
  vector: {
    enabled: boolean
    providerKind?: ChatRecallEmbeddingProviderKind
    providerId?: string
    model?: string
    dimensions?: number
    batchSize: number
    concurrency: number
    indexStrategy: ChatRecallIndexStrategy
  }
  rerank: {
    limit: number
    rrfK: number
    recencyHalfLifeDays: number
    mmrLambda: number
  }
  worker: {
    enabled: boolean
    pollIntervalMs: number
    maxAttempts: number
  }
}

/**
 * Validates and bounds an operator-supplied recall config.
 *
 * The numeric bounds are guard rails against settings that would overload the
 * embedding provider or the database: batch size and concurrency cap the in
 * flight embedding load, `pollIntervalMs` keeps the worker from busy-looping,
 * and `mmrLambda` stays in the 0..1 range the reranker expects. `.strict()`
 * rejects unknown keys so a typo in a saved config surfaces as an error instead
 * of being silently ignored.
 */
export const ChatRecallConfigSchema = z
  .object({
    vector: z
      .object({
        enabled: z.boolean().optional(),
        providerKind: z.enum(['openai', 'openrouter', 'vllm']).optional(),
        providerId: z.string().min(1).optional(),
        model: z.string().min(1).optional(),
        dimensions: z.number().int().positive().optional(),
        batchSize: z.number().int().min(1).max(256).optional(),
        concurrency: z.number().int().min(1).max(8).optional(),
        indexStrategy: z.enum(['auto', 'halfvec_hnsw', 'binary_quantized_hnsw', 'exact_only']).optional()
      })
      .strict()
      .optional(),
    rerank: z
      .object({
        limit: z.number().int().min(1).max(50).optional(),
        rrfK: z.number().positive().optional(),
        recencyHalfLifeDays: z.number().positive().optional(),
        mmrLambda: z.number().min(0).max(1).optional()
      })
      .strict()
      .optional(),
    worker: z
      .object({
        enabled: z.boolean().optional(),
        pollIntervalMs: z.number().int().min(250).max(300_000).optional(),
        maxAttempts: z.number().int().min(1).max(20).optional()
      })
      .strict()
      .optional()
  })
  .strict()

/**
 * Registers the recall config under one app-config key.
 *
 * Stored encrypted because the embedding `providerId` references provider
 * credentials. Recall ships disabled by default (`vector.enabled: false`): an
 * operator must pick a provider and model before any chat content is embedded.
 */
export const ChatRecallConfigDefinition = defineAppConfig<ConfigureJsonValue>({
  key: 'ai_agent.chat_history_recall',
  description: 'Chat history recall search, embedding, and rerank settings',
  encrypted: true,
  schema: ChatRecallConfigSchema as unknown as z.ZodType<ConfigureJsonValue>,
  defaultValue: {
    vector: {
      enabled: false,
      batchSize: 32,
      concurrency: 1,
      indexStrategy: 'auto'
    },
    rerank: {
      limit: 10,
      rrfK: 60,
      recencyHalfLifeDays: 30,
      mmrLambda: 0.78
    },
    worker: {
      enabled: true,
      pollIntervalMs: 10_000,
      maxAttempts: 5
    }
  }
})

registerAppConfigDefinitions([ChatRecallConfigDefinition])

/**
 * Parses an unknown stored value and applies defaults for every missing field.
 *
 * Accepts `unknown` (not {@link ChatRecallConfig}) because the input comes
 * straight from the app-config store and has not been validated yet; a nullish
 * value is treated as an empty config so a never-configured install still gets a
 * usable defaulted shape.
 */
export function normalizeChatRecallConfig(value: unknown): NormalizedChatRecallConfig {
  const parsed = ChatRecallConfigSchema.parse(value ?? {})
  return {
    vector: {
      enabled: parsed.vector?.enabled ?? false,
      providerKind: parsed.vector?.providerKind,
      providerId: parsed.vector?.providerId,
      model: parsed.vector?.model,
      dimensions: parsed.vector?.dimensions,
      batchSize: parsed.vector?.batchSize ?? 32,
      concurrency: parsed.vector?.concurrency ?? 1,
      indexStrategy: parsed.vector?.indexStrategy ?? 'auto'
    },
    rerank: {
      limit: parsed.rerank?.limit ?? 10,
      rrfK: parsed.rerank?.rrfK ?? 60,
      recencyHalfLifeDays: parsed.rerank?.recencyHalfLifeDays ?? 30,
      mmrLambda: parsed.rerank?.mmrLambda ?? 0.78
    },
    worker: {
      enabled: parsed.worker?.enabled ?? true,
      pollIntervalMs: parsed.worker?.pollIntervalMs ?? 10_000,
      maxAttempts: parsed.worker?.maxAttempts ?? 5
    }
  }
}

/**
 * Derives the embedding profile from config, or `undefined` when recall cannot
 * embed yet.
 *
 * Returns `undefined` unless recall is enabled and the three identifying fields
 * (provider kind, provider id, model) are all present. Callers treat the absence
 * of a profile as one of the reasons recall is unavailable, so this is the single
 * gate that decides whether embedding is even possible.
 */
export function embeddingProfileFromConfig(config: NormalizedChatRecallConfig) {
  if (!config.vector.enabled) return undefined
  if (!config.vector.providerKind || !config.vector.providerId || !config.vector.model) return undefined
  return {
    providerKind: config.vector.providerKind,
    providerId: config.vector.providerId,
    model: config.vector.model,
    dimensions: config.vector.dimensions,
    batchSize: config.vector.batchSize,
    concurrency: config.vector.concurrency,
    indexStrategy: config.vector.indexStrategy
  }
}
