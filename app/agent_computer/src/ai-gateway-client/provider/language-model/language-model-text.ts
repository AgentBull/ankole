import type { SharedProviderMetadata } from '../shared/shared-provider-metadata'

/**
 * Text that the model has generated.
 */
export type LanguageModelText = {
  type: 'text'

  /**
   * The text content.
   */
  text: string

  providerMetadata?: SharedProviderMetadata
}
