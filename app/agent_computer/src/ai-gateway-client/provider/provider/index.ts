import type { EmbeddingModel } from '../embedding-model/embedding-model'
import type { ImageModel } from '../image-model/image-model'
import type { LanguageModel } from '../language-model/language-model'
import type { RerankingModel } from '../reranking-model/reranking-model'
import type { TranscriptionModel } from '../transcription-model/transcription-model'

/**
 * Provider for language, text embedding, and image generation models.
 */
export interface Provider {
  /**
   * Returns the language model with the given id.
   * The model id is then passed to the provider function to get the model.
   *
   * @param {string} modelId - The id of the model to return.
   *
   * @returns {LanguageModel} The language model associated with the id
   *
   * @throws {NoSuchModelError} If no such model exists.
   */
  languageModel(modelId: string): LanguageModel

  /**
   * Returns the text embedding model with the given id.
   * The model id is then passed to the provider function to get the model.
   *
   * @param {string} modelId - The id of the model to return.
   *
   * @returns {EmbeddingModel} The embedding model associated with the id
   *
   * @throws {NoSuchModelError} If no such model exists.
   */
  embeddingModel(modelId: string): EmbeddingModel

  /**
   * Returns the image model with the given id.
   * The model id is then passed to the provider function to get the model.
   *
   * @param {string} modelId - The id of the model to return.
   *
   * @returns {ImageModel} The image model associated with the id
   */
  imageModel(modelId: string): ImageModel

  /**
   * Returns the transcription model with the given id.
   * The model id is then passed to the provider function to get the model.
   *
   * @param {string} modelId - The id of the model to return.
   *
   * @returns {TranscriptionModel} The transcription model associated with the id
   */
  transcriptionModel?(modelId: string): TranscriptionModel

  /**
   * Returns the reranking model with the given id.
   * The model id is then passed to the provider function to get the model.
   *
   * @param {string} modelId - The id of the model to return.
   *
   * @returns {RerankingModel} The reranking model associated with the id
   *
   * @throws {NoSuchModelError} If no such model exists.
   */
  rerankingModel?(modelId: string): RerankingModel
}
