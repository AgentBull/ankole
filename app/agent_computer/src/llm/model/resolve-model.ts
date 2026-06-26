// @ts-nocheck
import type {
  EmbeddingModelV4,
  ImageModelV4,
  LanguageModelV4,
  ProviderV4,
  RerankingModelV4,
  TranscriptionModelV4
} from '@/llm/provider'
import { UnsupportedModelVersionError } from '../error'
import type { EmbeddingModel } from '../types/embedding-model'
import type { LanguageModel } from '../types/language-model'
import type { TranscriptionModel } from '../types/transcription-model'
import { asEmbeddingModelV4 } from './as-embedding-model-v4'
import { asImageModelV4 } from './as-image-model-v4'
import { asLanguageModelV4 } from './as-language-model-v4'
import { asRerankingModelV4 } from './as-reranking-model-v4'
import { asTranscriptionModelV4 } from './as-transcription-model-v4'
import { asProviderV4 } from './as-provider-v4'
import type { ImageModel } from '../types/image-model'
import type { RerankingModel } from '../types/reranking-model'

export function resolveLanguageModel(model: LanguageModel): LanguageModelV4 {
  if (typeof model === 'string') {
    return getGlobalProvider().languageModel(model)
  }

  if (!['v4', 'v3', 'v2'].includes(model.specificationVersion)) {
    const unsupportedModel: any = model
    throw new UnsupportedModelVersionError({
      version: unsupportedModel.specificationVersion,
      provider: unsupportedModel.provider,
      modelId: unsupportedModel.modelId
    })
  }

  return asLanguageModelV4(model)
}

export function resolveEmbeddingModel(model: EmbeddingModel): EmbeddingModelV4 {
  if (typeof model === 'string') {
    return getGlobalProvider().embeddingModel(model)
  }

  if (!['v4', 'v3', 'v2'].includes(model.specificationVersion)) {
    const unsupportedModel: any = model
    throw new UnsupportedModelVersionError({
      version: unsupportedModel.specificationVersion,
      provider: unsupportedModel.provider,
      modelId: unsupportedModel.modelId
    })
  }

  return asEmbeddingModelV4(model)
}

export function resolveTranscriptionModel(model: TranscriptionModel): TranscriptionModelV4 | undefined {
  if (typeof model === 'string') {
    return getGlobalProvider().transcriptionModel?.(model)
  }

  if (!['v4', 'v3', 'v2'].includes(model.specificationVersion)) {
    const unsupportedModel: any = model
    throw new UnsupportedModelVersionError({
      version: unsupportedModel.specificationVersion,
      provider: unsupportedModel.provider,
      modelId: unsupportedModel.modelId
    })
  }

  return asTranscriptionModelV4(model)
}

export function resolveImageModel(model: ImageModel): ImageModelV4 {
  if (typeof model === 'string') {
    return getGlobalProvider().imageModel(model)
  }

  if (!['v4', 'v3', 'v2'].includes(model.specificationVersion)) {
    const unsupportedModel: any = model
    throw new UnsupportedModelVersionError({
      version: unsupportedModel.specificationVersion,
      provider: unsupportedModel.provider,
      modelId: unsupportedModel.modelId
    })
  }

  return asImageModelV4(model)
}

export function resolveRerankingModel(model: RerankingModel): RerankingModelV4 {
  if (typeof model === 'string') {
    const provider = getGlobalProvider()
    const rerankingModel = provider.rerankingModel

    if (!rerankingModel) {
      throw new Error(
        'The default provider does not support reranking models. ' +
          'Please use a RerankingModel object from a provider.'
      )
    }

    return rerankingModel(model)
  }

  if (model.specificationVersion !== 'v4' && model.specificationVersion !== 'v3') {
    const unsupportedModel: any = model
    throw new UnsupportedModelVersionError({
      version: unsupportedModel.specificationVersion,
      provider: unsupportedModel.provider,
      modelId: unsupportedModel.modelId
    })
  }

  return asRerankingModelV4(model)
}

function getGlobalProvider(): ProviderV4 {
  const provider = getRawGlobalProvider('model')
  return asProviderV4(provider)
}

function getRawGlobalProvider(modelType: string): ProviderV4 | ProviderV3 | ProviderV2 {
  const provider = globalThis.AI_SDK_DEFAULT_PROVIDER
  if (!provider) {
    throw new Error(
      `String ${modelType} ids require globalThis.AI_SDK_DEFAULT_PROVIDER. Pass a concrete provider model object instead.`
    )
  }
  return provider
}
