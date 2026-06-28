import type { ImageModel, ImageModelCallOptions, ImageModelResult } from '@/ai-gateway-client/provider'
import { asArray } from '@/ai-gateway-client/provider-utils'
import { asImageModel } from '../model/as-image-model'
import type { ImageModelMiddleware } from '../types'

/**
 * Wraps an ImageModel instance with middleware functionality.
 * This function allows you to apply middleware to transform parameters
 * and wrap generate operations of an image model.
 *
 * @param options - Configuration options for wrapping the image model.
 * @param options.model - The original ImageModel instance to be wrapped.
 * @param options.middleware - The middleware to be applied to the image model. When multiple middlewares are provided, the first middleware will transform the input first, and the last middleware will be wrapped directly around the model.
 * @param options.modelId - Optional custom model ID to override the original model's ID.
 * @param options.providerId - Optional custom provider ID to override the original model's provider ID.
 * @returns A new ImageModel instance with middleware applied.
 */
export const wrapImageModel = ({
  model: inputModel,
  middleware: middlewareArg,
  modelId,
  providerId
}: {
  model: ImageModel
  middleware: ImageModelMiddleware | ImageModelMiddleware[]
  modelId?: string
  providerId?: string
}): ImageModel => {
  const model = asImageModel(inputModel)
  return [...asArray(middlewareArg)].reverse().reduce((wrappedModel, middleware) => {
    return doWrap({ model: wrappedModel, middleware, modelId, providerId })
  }, model)
}

const doWrap = ({
  model,
  middleware: { transformParams, wrapGenerate, overrideProvider, overrideModelId, overrideMaxImagesPerCall },
  modelId,
  providerId
}: {
  model: ImageModel
  middleware: ImageModelMiddleware
  modelId?: string
  providerId?: string
}): ImageModel => {
  async function doTransform({ params }: { params: ImageModelCallOptions }) {
    return transformParams ? await transformParams({ params, model }) : params
  }

  const maxImagesPerCallRaw = overrideMaxImagesPerCall?.({ model }) ?? model.maxImagesPerCall

  // Ensure provider implementations that rely on `this` inside `maxImagesPerCall`
  // keep working after the value is copied onto the wrapper object.
  const maxImagesPerCall =
    maxImagesPerCallRaw instanceof Function ? maxImagesPerCallRaw.bind(model) : maxImagesPerCallRaw

  return {
    provider: providerId ?? overrideProvider?.({ model }) ?? model.provider,
    modelId: modelId ?? overrideModelId?.({ model }) ?? model.modelId,
    maxImagesPerCall,
    async doGenerate(params: ImageModelCallOptions): Promise<ImageModelResult> {
      const transformedParams = await doTransform({ params })
      const doGenerate = async () => await model.doGenerate(transformedParams)
      return wrapGenerate
        ? await wrapGenerate({
            doGenerate,
            params: transformedParams,
            model
          })
        : await doGenerate()
    }
  }
}
