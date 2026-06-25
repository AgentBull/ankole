// @ts-nocheck
import type {
  ImageModelV2,
  ImageModelV3,
  ImageModelV4,
  ImageModelV4ProviderMetadata,
  ImageModelV2ProviderMetadata
} from '@/llm/provider'

/**
 * Image model that is used by the AI SDK.
 */
export type ImageModel = string | ImageModelV4 | ImageModelV3 | ImageModelV2

/**
 * Metadata from the model provider for this call.
 */
export type ImageModelProviderMetadata = ImageModelV4ProviderMetadata | ImageModelV2ProviderMetadata
