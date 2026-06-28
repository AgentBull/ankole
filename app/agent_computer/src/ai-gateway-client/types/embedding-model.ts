import type { EmbeddingModel as ProviderEmbeddingModel, EmbeddingModelEmbedding } from '@/ai-gateway-client/provider'

/**
 * Embedding model that is used by the AI SDK.
 */
export type EmbeddingModel = ProviderEmbeddingModel

/**
 * Embedding.
 */
export type Embedding = EmbeddingModelEmbedding
