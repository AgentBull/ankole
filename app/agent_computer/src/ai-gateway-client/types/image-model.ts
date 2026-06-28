import type {
  ImageModel as ProviderImageModel,
  ImageModelProviderMetadata as ProviderImageModelProviderMetadata
} from '@/ai-gateway-client/provider'

/**
 * Image model that is used by the AI SDK.
 */
export type ImageModel = ProviderImageModel

/**
 * Metadata from the model provider for this call.
 */
export type ImageModelProviderMetadata = ProviderImageModelProviderMetadata
