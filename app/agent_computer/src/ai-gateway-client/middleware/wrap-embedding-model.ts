import type { EmbeddingModel, EmbeddingModelCallOptions, EmbeddingModelResult } from '@/ai-gateway-client/provider'
import { asArray } from '@/ai-gateway-client/provider-utils'
import { asEmbeddingModel } from '../model/as-embedding-model'
import type { EmbeddingModelMiddleware } from '../types'

/**
 * Wraps an EmbeddingModel instance with middleware functionality.
 * This function allows you to apply middleware to transform parameters,
 * wrap embed operations of an embedding model.
 *
 * @param options - Configuration options for wrapping the embedding model.
 * @param options.model - The original EmbeddingModel instance to be wrapped.
 * @param options.middleware - The middleware to be applied to the embedding model. When multiple middlewares are provided, the first middleware will transform the input first, and the last middleware will be wrapped directly around the model.
 * @param options.modelId - Optional custom model ID to override the original model's ID.
 * @param options.providerId - Optional custom provider ID to override the original model's provider ID.
 * @returns A new EmbeddingModel instance with middleware applied.
 */
export const wrapEmbeddingModel = ({
  model: inputModel,
  middleware: middlewareArg,
  modelId,
  providerId
}: {
  model: EmbeddingModel
  middleware: EmbeddingModelMiddleware | EmbeddingModelMiddleware[]
  modelId?: string
  providerId?: string
}): EmbeddingModel => {
  const model = asEmbeddingModel(inputModel)
  return [...asArray(middlewareArg)].reverse().reduce((wrappedModel, middleware) => {
    return doWrap({ model: wrappedModel, middleware, modelId, providerId })
  }, model)
}

const doWrap = ({
  model,
  middleware: {
    transformParams,
    wrapEmbed,
    overrideProvider,
    overrideModelId,
    overrideMaxEmbeddingsPerCall,
    overrideSupportsParallelCalls
  },
  modelId,
  providerId
}: {
  model: EmbeddingModel
  middleware: EmbeddingModelMiddleware
  modelId?: string
  providerId?: string
}): EmbeddingModel => {
  async function doTransform({ params }: { params: EmbeddingModelCallOptions }) {
    return transformParams ? await transformParams({ params, model }) : params
  }

  return {
    provider: providerId ?? overrideProvider?.({ model }) ?? model.provider,
    modelId: modelId ?? overrideModelId?.({ model }) ?? model.modelId,
    maxEmbeddingsPerCall: overrideMaxEmbeddingsPerCall?.({ model }) ?? model.maxEmbeddingsPerCall,
    supportsParallelCalls: overrideSupportsParallelCalls?.({ model }) ?? model.supportsParallelCalls,
    async doEmbed(params: EmbeddingModelCallOptions): Promise<EmbeddingModelResult> {
      const transformedParams = await doTransform({ params })
      const doEmbed = async () => await model.doEmbed(transformedParams)
      return wrapEmbed
        ? await wrapEmbed({
            doEmbed,
            params: transformedParams,
            model
          })
        : await doEmbed()
    }
  }
}
