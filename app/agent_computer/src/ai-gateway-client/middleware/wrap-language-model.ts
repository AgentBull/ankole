import type {
  LanguageModel,
  LanguageModelCallOptions,
  LanguageModelGenerateResult,
  LanguageModelStreamResult
} from '@/ai-gateway-client/provider'
import { asArray } from '@/ai-gateway-client/provider-utils'
import { asLanguageModel } from '../model/as-language-model'
import type { LanguageModelMiddleware } from '../types'

/**
 * Wraps a LanguageModel instance with middleware functionality.
 * This function allows you to apply middleware to transform parameters,
 * wrap generate operations, and wrap stream operations of a language model.
 *
 * @param options - Configuration options for wrapping the language model.
 * @param options.model - The original LanguageModel instance to be wrapped.
 * @param options.middleware - The middleware to be applied to the language model. When multiple middlewares are provided, the first middleware will transform the input first, and the last middleware will be wrapped directly around the model.
 * @param options.modelId - Optional custom model ID to override the original model's ID.
 * @param options.providerId - Optional custom provider ID to override the original model's provider ID.
 * @returns A new LanguageModel instance with middleware applied.
 */
export const wrapLanguageModel = ({
  model: inputModel,
  middleware: middlewareArg,
  modelId,
  providerId
}: {
  model: LanguageModel
  middleware: LanguageModelMiddleware | LanguageModelMiddleware[]
  modelId?: string
  providerId?: string
}): LanguageModel => {
  const model = asLanguageModel(inputModel)
  return [...asArray(middlewareArg)].reverse().reduce((wrappedModel, middleware) => {
    return doWrap({ model: wrappedModel, middleware, modelId, providerId })
  }, model)
}

const doWrap = ({
  model,
  middleware: { transformParams, wrapGenerate, wrapStream, overrideProvider, overrideModelId, overrideSupportedUrls },
  modelId,
  providerId
}: {
  model: LanguageModel
  middleware: LanguageModelMiddleware
  modelId?: string
  providerId?: string
}): LanguageModel => {
  async function doTransform({ params, type }: { params: LanguageModelCallOptions; type: 'generate' | 'stream' }) {
    return transformParams ? await transformParams({ params, type, model }) : params
  }

  return {
    provider: providerId ?? overrideProvider?.({ model }) ?? model.provider,
    modelId: modelId ?? overrideModelId?.({ model }) ?? model.modelId,
    supportedUrls: overrideSupportedUrls?.({ model }) ?? model.supportedUrls,

    async doGenerate(params: LanguageModelCallOptions): Promise<LanguageModelGenerateResult> {
      const transformedParams = await doTransform({ params, type: 'generate' })
      const doGenerate = async () => await model.doGenerate(transformedParams)
      const doStream = async () => await model.doStream(transformedParams)
      return wrapGenerate
        ? await wrapGenerate({
            doGenerate,
            doStream,
            params: transformedParams,
            model
          })
        : await doGenerate()
    },

    async doStream(params: LanguageModelCallOptions): Promise<LanguageModelStreamResult> {
      const transformedParams = await doTransform({ params, type: 'stream' })
      const doGenerate = async () => await model.doGenerate(transformedParams)
      const doStream = async () => await model.doStream(transformedParams)
      return wrapStream
        ? await wrapStream({
            doGenerate,
            doStream,
            params: transformedParams,
            model
          })
        : await doStream()
    }
  }
}
