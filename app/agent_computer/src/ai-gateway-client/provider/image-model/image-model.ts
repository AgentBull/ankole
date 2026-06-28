import type { ImageModelCallOptions } from './image-model-call-options'
import type { ImageModelResult } from './image-model-result'

type GetMaxImagesPerCallFunction = (options: {
  modelId: string
}) => PromiseLike<number | undefined> | number | undefined

/**
 * Image generation model specification version 3.
 */
export type ImageModel = {
  /**
   * The image model must specify which image model interface
   * version it implements. This will allow us to evolve the image
   * model interface and retain backwards compatibility. The different
   * implementation versions can be handled as a discriminated union
   * on our side.
   */
  /**
   * Name of the provider for logging purposes.
   */
  readonly provider: string

  /**
   * Provider-specific model ID for logging purposes.
   */
  readonly modelId: string

  /**
   * Limit of how many images can be generated in a single API call.
   * Can be set to a number for a fixed limit, to undefined to use
   * the global limit, or a function that returns a number or undefined,
   * optionally as a promise.
   */
  readonly maxImagesPerCall: number | undefined | GetMaxImagesPerCallFunction

  /**
   * Generates an array of images.
   */
  doGenerate(options: ImageModelCallOptions): PromiseLike<ImageModelResult>
}
