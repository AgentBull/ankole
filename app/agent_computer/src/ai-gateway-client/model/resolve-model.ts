import type {
  EmbeddingModel as ProviderEmbeddingModel,
  ImageModel as ProviderImageModel,
  LanguageModel as ProviderLanguageModel,
  RerankingModel as ProviderRerankingModel,
  TranscriptionModel as ProviderTranscriptionModel
} from '@/ai-gateway-client/provider'
import type { EmbeddingModel as EmbeddingModelInput } from '../types/embedding-model'
import type { LanguageModel as LanguageModelInput } from '../types/language-model'
import type { TranscriptionModel as TranscriptionModelInput } from '../types/transcription-model'

import type { ImageModel as ImageModelInput } from '../types/image-model'
import type { RerankingModel as RerankingModelInput } from '../types/reranking-model'

export function resolveLanguageModel(model: LanguageModelInput): ProviderLanguageModel {
  return model
}

export function resolveEmbeddingModel(model: EmbeddingModelInput): ProviderEmbeddingModel {
  return model
}

export function resolveTranscriptionModel(model: TranscriptionModelInput): ProviderTranscriptionModel | undefined {
  return model
}

export function resolveImageModel(model: ImageModelInput): ProviderImageModel {
  return model
}

export function resolveRerankingModel(model: RerankingModelInput): ProviderRerankingModel {
  return model
}
