import type { ImageModel } from '../image-model/image-model'
import type { ImageModelCallOptions } from '../image-model/image-model-call-options'

/**
 * Middleware for ImageModel.
 * This type defines the structure for middleware that can be used to modify
 * the behavior of ImageModel operations.
 */
export type ImageModelMiddleware = {
  /**
   * Override the provider name if desired.
   * @param options.model - The image model instance.
   */
  overrideProvider?: (options: { model: ImageModel }) => string

  /**
   * Override the model ID if desired.
   * @param options.model - The image model instance.
   */
  overrideModelId?: (options: { model: ImageModel }) => string

  /**
   * Override the limit of how many images can be generated in a single API call if desired.
   * @param options.model - The image model instance.
   */
  overrideMaxImagesPerCall?: (options: { model: ImageModel }) => ImageModel['maxImagesPerCall']

  /**
   * Transforms the parameters before they are passed to the image model.
   * @param options - Object containing the parameters.
   * @param options.params - The original parameters for the image model call.
   * @returns A promise that resolves to the transformed parameters.
   */
  transformParams?: (options: {
    params: ImageModelCallOptions
    model: ImageModel
  }) => PromiseLike<ImageModelCallOptions>

  /**
   * Wraps the generate operation of the image model.
   *
   * @param options - Object containing the generate function, parameters, and model.
   * @param options.doGenerate - The original generate function.
   * @param options.params - The parameters for the generate call. If the
   * `transformParams` middleware is used, this will be the transformed parameters.
   * @param options.model - The image model instance.
   * @returns A promise that resolves to the result of the generate operation.
   */
  wrapGenerate?: (options: {
    doGenerate: () => ReturnType<ImageModel['doGenerate']>
    params: ImageModelCallOptions
    model: ImageModel
  }) => Promise<Awaited<ReturnType<ImageModel['doGenerate']>>>
}
