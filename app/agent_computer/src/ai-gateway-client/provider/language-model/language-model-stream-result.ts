import type { SharedHeaders } from '../shared'
import type { LanguageModelStreamPart } from './language-model-stream-part'

/**
 * The result of a language model doStream call.
 */
export type LanguageModelStreamResult = {
  /**
   * The stream.
   */
  stream: ReadableStream<LanguageModelStreamPart>

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
   * Optional response data.
   */
  response?: {
    /**
     * Response headers.
     */
    headers?: SharedHeaders
  }
}
