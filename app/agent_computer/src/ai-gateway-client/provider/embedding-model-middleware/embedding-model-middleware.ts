import type { EmbeddingModel } from '../embedding-model/embedding-model'
import type { EmbeddingModelCallOptions } from '../embedding-model/embedding-model-call-options'

/**
 * Middleware for EmbeddingModel.
 * This type defines the structure for middleware that can be used to modify
 * the behavior of EmbeddingModel operations.
 */
export type EmbeddingModelMiddleware = {
  /**
   * Override the provider name if desired.
   * @param options.model - The embedding model instance.
   */
  overrideProvider?: (options: { model: EmbeddingModel }) => string

  /**
   * Override the model ID if desired.
   * @param options.model - The embedding model instance.
   */
  overrideModelId?: (options: { model: EmbeddingModel }) => string

  /**
   * Override the limit of how many embeddings can be generated in a single API call if desired.
   * @param options.model - The embedding model instance.
   */
  overrideMaxEmbeddingsPerCall?: (options: {
    model: EmbeddingModel
  }) => PromiseLike<number | undefined> | number | undefined

  /**
   * Override support for handling multiple embedding calls in parallel, if desired..
   * @param options.model - The embedding model instance.
   */
  overrideSupportsParallelCalls?: (options: { model: EmbeddingModel }) => PromiseLike<boolean> | boolean

  /**
   * Transforms the parameters before they are passed to the embed model.
   * @param options - Object containing the type of operation and the parameters.
   * @param options.params - The original parameters for the embedding model call.
   * @returns A promise that resolves to the transformed parameters.
   */
  transformParams?: (options: {
    params: EmbeddingModelCallOptions
    model: EmbeddingModel
  }) => PromiseLike<EmbeddingModelCallOptions>

  /**
   * Wraps the embed operation of the embedding model.
   *
   * @param options - Object containing the embed function, parameters, and model.
   * @param options.doEmbed - The original embed function.
   * @param options.params - The parameters for the embed call. If the
   * `transformParams` middleware is used, this will be the transformed parameters.
   * @param options.model - The embedding model instance.
   * @returns A promise that resolves to the result of the generate operation.
   */
  wrapEmbed?: (options: {
    doEmbed: () => ReturnType<EmbeddingModel['doEmbed']>
    params: EmbeddingModelCallOptions
    model: EmbeddingModel
  }) => Promise<Awaited<ReturnType<EmbeddingModel['doEmbed']>>>
}
