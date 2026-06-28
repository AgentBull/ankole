import type { SharedHeaders, SharedProviderMetadata, SharedWarning } from '../shared'
import type { EmbeddingModelEmbedding } from './embedding-model-embedding'

/**
 * The result of a embedding model doEmbed call.
 */
export type EmbeddingModelResult = {
  /**
   * Generated embeddings. They are in the same order as the input values.
   */
  embeddings: Array<EmbeddingModelEmbedding>

  /**
   * Token usage. We only have input tokens for embeddings.
   */
  usage?: { tokens: number }

  /**
   * Additional provider-specific metadata. They are passed through
   * from the provider to the AI SDK and enable provider-specific
   * results that can be fully encapsulated in the provider.
   */
  providerMetadata?: SharedProviderMetadata

  /**
   * Optional response information for debugging purposes.
   */
  response?: {
    /**
     * Response headers.
     */
    headers?: SharedHeaders

    /**
     * The response body.
     */
    body?: unknown
  }

  /**
   * Warnings for the call, e.g. unsupported settings.
   */
  warnings: Array<SharedWarning>
}
