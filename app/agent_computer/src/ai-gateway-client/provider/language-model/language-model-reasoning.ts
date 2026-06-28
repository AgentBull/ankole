import type { SharedProviderMetadata } from '../shared'

/**
 * Reasoning that the model has generated.
 */
export type LanguageModelReasoning = {
  type: 'reasoning'
  text: string

  /**
   * Optional provider-specific metadata for the reasoning part.
   */
  providerMetadata?: SharedProviderMetadata
}
