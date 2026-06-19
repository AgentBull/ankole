// @ts-nocheck
import type { RerankingModelV3, RerankingModelV4 } from '@/llm/provider'

/**
 * Reranking model that is used by the AI SDK.
 */
export type RerankingModel = string | RerankingModelV4 | RerankingModelV3
