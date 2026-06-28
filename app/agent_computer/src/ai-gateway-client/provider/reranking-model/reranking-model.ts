import type { RerankingModelCallOptions } from './reranking-model-call-options'
import type { RerankingModelResult } from './reranking-model-result'

/**
 * Specification for a reranking model that implements the reranking model interface version 3.
 */
export type RerankingModel = {
  /**
   * The reranking model must specify which reranking model interface version it implements.
   */
  /**
   * Provider ID.
   */
  readonly provider: string

  /**
   * Provider-specific model ID.
   */
  readonly modelId: string

  /**
   * Reranking a list of documents using the query.
   */
  // Naming: "do" prefix to prevent accidental direct usage of the method by the user.
  doRerank(options: RerankingModelCallOptions): PromiseLike<RerankingModelResult>
}
