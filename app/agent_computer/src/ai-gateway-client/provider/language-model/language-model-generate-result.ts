import type { SharedHeaders, SharedWarning } from '../shared'
import type { SharedProviderMetadata } from '../shared/shared-provider-metadata'
import type { LanguageModelContent } from './language-model-content'
import type { LanguageModelFinishReason } from './language-model-finish-reason'
import type { LanguageModelResponseMetadata } from './language-model-response-metadata'
import type { LanguageModelUsage } from './language-model-usage'

/**
 * The result of a language model doGenerate call.
 */
export type LanguageModelGenerateResult = {
  /**
   * Ordered content that the model has generated.
   */
  content: Array<LanguageModelContent>

  /**
   * The finish reason.
   */
  finishReason: LanguageModelFinishReason

  /**
   * The usage information.
   */
  usage: LanguageModelUsage

  /**
   * Additional provider-specific metadata. They are passed through
   * from the provider to the AI SDK and enable provider-specific
   * results that can be fully encapsulated in the provider.
   */
  providerMetadata?: SharedProviderMetadata

  /**
   * Optional request information for telemetry and debugging purposes.
   */
  request?: {
    /**
     * Request HTTP body that was sent to the provider API.
     */
    body?: unknown
  }

  /**
   * Optional response information for telemetry and debugging purposes.
   */
  response?: LanguageModelResponseMetadata & {
    /**
     * Response headers.
     */
    headers?: SharedHeaders

    /**
     * Response HTTP body.
     */
    body?: unknown
  }

  /**
   * Warnings for the call, e.g. unsupported settings.
   */
  warnings: Array<SharedWarning>
}
