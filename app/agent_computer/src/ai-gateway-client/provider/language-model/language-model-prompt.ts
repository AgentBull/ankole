import type { JSONValue } from '../json-value/json-value'
import type { SharedFileData, SharedFileDataData, SharedFileDataUrl } from '../shared/shared-file-data'
import type { SharedProviderOptions } from '../shared/shared-provider-options'

/**
 * A prompt is a list of messages.
 *
 * Note: Not all models and prompt formats support multi-modal inputs and
 * tool calls. The validation happens at runtime.
 *
 * Note: This is not a user-facing prompt. The AI SDK methods will map the
 * user-facing prompt types such as chat or instruction prompts to this format.
 */
export type LanguageModelPrompt = Array<LanguageModelMessage>

export type LanguageModelMessage =
  // Note: there could be additional parts for each role in the future,
  // e.g. when the assistant can return images or the user can share files
  // such as PDFs.
  (
    | {
        role: 'system'
        content: string
      }
    | {
        role: 'user'
        content: Array<LanguageModelTextPart | LanguageModelFilePart>
      }
    | {
        role: 'assistant'
        content: Array<
          | LanguageModelTextPart
          | LanguageModelFilePart
          | LanguageModelCustomPart
          | LanguageModelReasoningPart
          | LanguageModelReasoningFilePart
          | LanguageModelToolCallPart
          | LanguageModelToolResultPart
        >
      }
    | {
        role: 'tool'
        content: Array<LanguageModelToolResultPart | LanguageModelToolApprovalResponsePart>
      }
  ) & {
    /**
     * Additional provider-specific options. They are passed through
     * to the provider from the AI SDK and enable provider-specific
     * functionality that can be fully encapsulated in the provider.
     */
    providerOptions?: SharedProviderOptions
  }

/**
 * Text content part of a prompt. It contains a string of text.
 */
export interface LanguageModelTextPart {
  type: 'text'

  /**
   * The text content.
   */
  text: string

  /**
   * Additional provider-specific options. They are passed through
   * to the provider from the AI SDK and enable provider-specific
   * functionality that can be fully encapsulated in the provider.
   */
  providerOptions?: SharedProviderOptions
}

/**
 * Reasoning content part of a prompt. It contains a string of reasoning text.
 */
export interface LanguageModelReasoningPart {
  type: 'reasoning'

  /**
   * The reasoning text.
   */
  text: string

  /**
   * Additional provider-specific options. They are passed through
   * to the provider from the AI SDK and enable provider-specific
   * functionality that can be fully encapsulated in the provider.
   */
  providerOptions?: SharedProviderOptions
}

/**
 * Reasoning file content part of a prompt. It contains a file generated as part of reasoning.
 */
export interface LanguageModelReasoningFilePart {
  type: 'reasoning-file'

  /**
   * File data as a tagged discriminated union:
   *
   * - `{ type: 'data', data }`: raw bytes (Uint8Array) or base64-encoded string.
   * - `{ type: 'url', url }`: a URL that points to the file.
   */
  data: SharedFileDataData | SharedFileDataUrl

  /**
   * IANA media type of the file.
   *
   * @see https://www.iana.org/assignments/media-types/media-types.xhtml
   */
  mediaType: string

  /**
   * Additional provider-specific options. They are passed through
   * to the provider from the AI SDK and enable provider-specific
   * functionality that can be fully encapsulated in the provider.
   */
  providerOptions?: SharedProviderOptions
}

/**
 * Provider-specific content part of a prompt. It contains no standardized
 * payload beyond provider-specific options.
 */
export interface LanguageModelCustomPart {
  type: 'custom'

  /**
   * The kind of custom content, in the format `{provider}.{provider-type}`.
   */
  kind: `${string}.${string}`

  /**
   * Additional provider-specific options. They are passed through
   * to the provider from the AI SDK and enable provider-specific
   * functionality that can be fully encapsulated in the provider.
   */
  providerOptions?: SharedProviderOptions
}

/**
 * File content part of a prompt. It contains a file.
 */
export interface LanguageModelFilePart {
  type: 'file'

  /**
   * Optional filename of the file.
   */
  filename?: string

  /**
   * File data as a tagged discriminated union:
   *
   * - `{ type: 'data', data }`: raw bytes (Uint8Array) or base64-encoded string.
   * - `{ type: 'url', url }`: a URL that points to the file.
   * - `{ type: 'reference', reference }`: a provider reference (`{ [provider]: id }`).
   * - `{ type: 'text', text }`: inline text content (e.g. an inline text document).
   */
  data: SharedFileData

  /**
   * Either a full IANA media type (`type/subtype`, e.g. `image/png`) or just
   * the top-level IANA segment (e.g. `image`, `audio`, `video`, `text`).
   *
   * `*`-subtype wildcards (e.g. `image/*`) are normalized as equivalent to the
   * top-level segment alone (e.g. `image`). Providers can use the helpers in
   * `@/ai-gateway-client/provider-utils` (`isFullMediaType`, `getTopLevelMediaType`,
   * `detectMediaType`) to resolve the field according to their API
   * requirements.
   *
   * @see https://www.iana.org/assignments/media-types/media-types.xhtml
   */
  mediaType: string

  /**
   * Additional provider-specific options. They are passed through
   * to the provider from the AI SDK and enable provider-specific
   * functionality that can be fully encapsulated in the provider.
   */
  providerOptions?: SharedProviderOptions
}

/**
 * Tool call content part of a prompt. It contains a tool call (usually generated by the AI model).
 */
export interface LanguageModelToolCallPart {
  type: 'tool-call'

  /**
   * ID of the tool call. This ID is used to match the tool call with the tool result.
   */
  toolCallId: string

  /**
   * Name of the tool that is being called.
   */
  toolName: string

  /**
   * Arguments of the tool call. This is a JSON-serializable object that matches the tool's input schema.
   */
  input: unknown

  /**
   * Whether the tool call will be executed by the provider.
   * If this flag is not set or is false, the tool call will be executed by the client.
   */
  providerExecuted?: boolean

  /**
   * Additional provider-specific options. They are passed through
   * to the provider from the AI SDK and enable provider-specific
   * functionality that can be fully encapsulated in the provider.
   */
  providerOptions?: SharedProviderOptions
}

/**
 * Tool result content part of a prompt. It contains the result of the tool call with the matching ID.
 */
export interface LanguageModelToolResultPart {
  type: 'tool-result'

  /**
   * ID of the tool call that this result is associated with.
   */
  toolCallId: string

  /**
   * Name of the tool that generated this result.
   */
  toolName: string

  /**
   * Result of the tool call.
   */
  output: LanguageModelToolResultOutput

  /**
   * Additional provider-specific options. They are passed through
   * to the provider from the AI SDK and enable provider-specific
   * functionality that can be fully encapsulated in the provider.
   */
  providerOptions?: SharedProviderOptions
}

/**
 * Tool approval response content part of a prompt. It contains the user's
 * decision to approve or deny a provider-executed tool call.
 */
export interface LanguageModelToolApprovalResponsePart {
  type: 'tool-approval-response'

  /**
   * ID of the approval request that this response refers to.
   */
  approvalId: string

  /**
   * Whether the approval was granted (true) or denied (false).
   */
  approved: boolean

  /**
   * Optional reason for approval or denial.
   */
  reason?: string

  /**
   * Additional provider-specific options. They are passed through
   * to the provider from the AI SDK and enable provider-specific
   * functionality that can be fully encapsulated in the provider.
   */
  providerOptions?: SharedProviderOptions
}

/**
 * Result of a tool call.
 */
export type LanguageModelToolResultOutput =
  | {
      /**
       * Text tool output that should be directly sent to the API.
       */
      type: 'text'
      value: string

      /**
       * Provider-specific options.
       */
      providerOptions?: SharedProviderOptions
    }
  | {
      type: 'json'
      value: JSONValue

      /**
       * Provider-specific options.
       */
      providerOptions?: SharedProviderOptions
    }
  | {
      /**
       * Type when the user has denied the execution of the tool call.
       */
      type: 'execution-denied'

      /**
       * Optional reason for the execution denial.
       */
      reason?: string

      /**
       * Provider-specific options.
       */
      providerOptions?: SharedProviderOptions
    }
  | {
      type: 'error-text'
      value: string

      /**
       * Provider-specific options.
       */
      providerOptions?: SharedProviderOptions
    }
  | {
      type: 'error-json'
      value: JSONValue

      /**
       * Provider-specific options.
       */
      providerOptions?: SharedProviderOptions
    }
  | {
      type: 'content'
      value: Array<
        | {
            type: 'text'

            /**
             * Text content.
             */
            text: string

            /**
             * Provider-specific options.
             */
            providerOptions?: SharedProviderOptions
          }
        | {
            type: 'file'

            /**
             * File data as a tagged discriminated union:
             *
             * - `{ type: 'data', data }`: raw bytes (Uint8Array) or base64-encoded string.
             * - `{ type: 'url', url }`: a URL that points to the file.
             * - `{ type: 'reference', reference }`: a provider reference (`{ [provider]: id }`).
             * - `{ type: 'text', text }`: inline text content (e.g. an inline text document).
             */
            data: SharedFileData

            /**
             * Either a full IANA media type (`type/subtype`, e.g. `image/png`) or just
             * the top-level IANA segment (e.g. `image`, `audio`, `video`, `text`).
             *
             * `*`-subtype wildcards (e.g. `image/*`) are normalized as equivalent to the
             * top-level segment alone (e.g. `image`). Providers can use the helpers in
             * `@/ai-gateway-client/provider-utils` (`isFullMediaType`, `getTopLevelMediaType`,
             * `detectMediaType`) to resolve the field according to their API
             * requirements.
             *
             * @see https://www.iana.org/assignments/media-types/media-types.xhtml
             */
            mediaType: string

            /**
             * Optional filename of the file.
             */
            filename?: string

            /**
             * Provider-specific options.
             */
            providerOptions?: SharedProviderOptions
          }
        | {
            /**
             * Custom content part. This can be used to implement
             * provider-specific content parts.
             */
            type: 'custom'

            /**
             * Provider-specific options.
             */
            providerOptions?: SharedProviderOptions
          }
      >
    }
