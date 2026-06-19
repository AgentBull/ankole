// @ts-nocheck
import type { EmbeddingModelV2, EmbeddingModelV3, EmbeddingModelV4, EmbeddingModelV4Embedding } from '@/llm/provider'

/**
 * Embedding model that is used by the AI SDK.
 */
export type EmbeddingModel = string | EmbeddingModelV4 | EmbeddingModelV3 | EmbeddingModelV2<string>

/**
 * Embedding.
 */
export type Embedding = EmbeddingModelV4Embedding
