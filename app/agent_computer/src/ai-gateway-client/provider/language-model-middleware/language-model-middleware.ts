import type { LanguageModel } from '../language-model/language-model'
import type { LanguageModelCallOptions } from '../language-model/language-model-call-options'
import type { LanguageModelGenerateResult } from '../language-model/language-model-generate-result'
import type { LanguageModelStreamResult } from '../language-model/language-model-stream-result'

/**
 * Experimental middleware for LanguageModel.
 * This type defines the structure for middleware that can be used to modify
 * the behavior of LanguageModel operations.
 */
export type LanguageModelMiddleware = {
  /**
   * Override the provider name if desired.
   * @param options.model - The language model instance.
   */
  overrideProvider?: (options: { model: LanguageModel }) => string

  /**
   * Override the model ID if desired.
   * @param options.model - The language model instance.
   */
  overrideModelId?: (options: { model: LanguageModel }) => string

  /**
   * Override the supported URLs if desired.
   * @param options.model - The language model instance.
   */
  overrideSupportedUrls?: (options: {
    model: LanguageModel
  }) => PromiseLike<Record<string, RegExp[]>> | Record<string, RegExp[]>

  /**
   * Transforms the parameters before they are passed to the language model.
   * @param options - Object containing the type of operation and the parameters.
   * @param options.type - The type of operation ('generate' or 'stream').
   * @param options.params - The original parameters for the language model call.
   * @returns A promise that resolves to the transformed parameters.
   */
  transformParams?: (options: {
    type: 'generate' | 'stream'
    params: LanguageModelCallOptions
    model: LanguageModel
  }) => PromiseLike<LanguageModelCallOptions>

  /**
   * Wraps the generate operation of the language model.
   * @param options - Object containing the generate function, parameters, and model.
   * @param options.doGenerate - The original generate function.
   * @param options.doStream - The original stream function.
   * @param options.params - The parameters for the generate call. If the
   * `transformParams` middleware is used, this will be the transformed parameters.
   * @param options.model - The language model instance.
   * @returns A promise that resolves to the result of the generate operation.
   */
  wrapGenerate?: (options: {
    doGenerate: () => PromiseLike<LanguageModelGenerateResult>
    doStream: () => PromiseLike<LanguageModelStreamResult>
    params: LanguageModelCallOptions
    model: LanguageModel
  }) => PromiseLike<LanguageModelGenerateResult>

  /**
   * Wraps the stream operation of the language model.
   *
   * @param options - Object containing the stream function, parameters, and model.
   * @param options.doGenerate - The original generate function.
   * @param options.doStream - The original stream function.
   * @param options.params - The parameters for the stream call. If the
   * `transformParams` middleware is used, this will be the transformed parameters.
   * @param options.model - The language model instance.
   * @returns A promise that resolves to the result of the stream operation.
   */
  wrapStream?: (options: {
    doGenerate: () => PromiseLike<LanguageModelGenerateResult>
    doStream: () => PromiseLike<LanguageModelStreamResult>
    params: LanguageModelCallOptions
    model: LanguageModel
  }) => PromiseLike<LanguageModelStreamResult>
}
