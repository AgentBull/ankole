import type { EmbeddingModelCallOptions } from '@/ai-gateway-client/provider'
import type { EmbeddingModelMiddleware } from '../types'
import { mergeObjects } from '../util/merge-objects'

/**
 * Applies default settings for an embedding model.
 */
export function defaultEmbeddingSettingsMiddleware({
  settings
}: {
  settings: Partial<{
    headers?: EmbeddingModelCallOptions['headers']
    providerOptions?: EmbeddingModelCallOptions['providerOptions']
  }>
}): EmbeddingModelMiddleware {
  return {
    transformParams: async ({ params }) => {
      return mergeObjects(settings, params) as EmbeddingModelCallOptions
    }
  }
}
