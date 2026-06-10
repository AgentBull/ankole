import { z } from 'zod'
import { defineAppConfig, registerAppConfigDefinitions } from '@/config/app-configure'
import type { ConfigureJsonValue } from '@/common/db-schema/app-configure'

export type ChatRecallEmbeddingProviderKind = 'openai' | 'openrouter' | 'vllm'
export type ChatRecallIndexStrategy = 'auto' | 'halfvec_hnsw' | 'binary_quantized_hnsw' | 'exact_only'

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
