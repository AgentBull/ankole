import type { Provider } from '@/ai-gateway-client/provider'
import type { ImageModelMiddleware } from '../types/image-model-middleware'
import type { LanguageModelMiddleware } from '../types/language-model-middleware'
import { wrapImageModel } from './wrap-image-model'
import { wrapLanguageModel } from './wrap-language-model'
import { asProvider } from '../model/as-provider'

/**
 * Wraps a Provider instance with middleware functionality.
 * This function allows you to apply middleware to all language models
 * from the provider, enabling you to transform parameters, wrap generate
 * operations, and wrap stream operations for every language model.
 *
 * @param options - Configuration options for wrapping the provider.
 * @param options.provider - The original Provider instance to be wrapped.
 * @param options.languageModelMiddleware - The middleware to be applied to all language models from the provider. When multiple middlewares are provided, the first middleware will transform the input first, and the last middleware will be wrapped directly around the model.
 * @param options.imageModelMiddleware - Optional middleware to be applied to all image models from the provider. When multiple middlewares are provided, the first middleware will transform the input first, and the last middleware will be wrapped directly around the model.
 * @returns A new Provider instance with middleware applied to all language models.
 */
export function wrapProvider({
  provider,
  languageModelMiddleware,
  imageModelMiddleware
}: {
  provider: Provider
  languageModelMiddleware: LanguageModelMiddleware | LanguageModelMiddleware[]
  imageModelMiddleware?: ImageModelMiddleware | ImageModelMiddleware[]
}): Provider {
  const providerV4 = asProvider(provider)
  return {
    languageModel: (modelId: string) =>
      wrapLanguageModel({
        model: providerV4.languageModel(modelId),
        middleware: languageModelMiddleware
      }),
    embeddingModel: providerV4.embeddingModel,
    imageModel: (modelId: string) => {
      let model = providerV4.imageModel(modelId)

      if (imageModelMiddleware != null) {
        model = wrapImageModel({ model, middleware: imageModelMiddleware })
      }

      return model
    },
    transcriptionModel: providerV4.transcriptionModel,
    rerankingModel: providerV4.rerankingModel
  }
}
