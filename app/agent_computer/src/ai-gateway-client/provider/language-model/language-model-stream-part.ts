import type { SharedProviderMetadata } from '../shared/shared-provider-metadata'
import type { SharedWarning } from '../shared/shared-warning'
import type { LanguageModelCustomContent } from './language-model-custom-content'
import type { LanguageModelFile } from './language-model-file'
import type { LanguageModelFinishReason } from './language-model-finish-reason'
import type { LanguageModelReasoningFile } from './language-model-reasoning-file'
import type { LanguageModelResponseMetadata } from './language-model-response-metadata'
import type { LanguageModelSource } from './language-model-source'
import type { LanguageModelToolApprovalRequest } from './language-model-tool-approval-request'
import type { LanguageModelToolCall } from './language-model-tool-call'
import type { LanguageModelToolResult } from './language-model-tool-result'
import type { LanguageModelUsage } from './language-model-usage'

export type LanguageModelStreamPart =
  // Text blocks:
  | {
      type: 'text-start'
      providerMetadata?: SharedProviderMetadata
      id: string
    }
  | {
      type: 'text-delta'
      id: string
      providerMetadata?: SharedProviderMetadata
      delta: string
    }
  | {
      type: 'text-end'
      providerMetadata?: SharedProviderMetadata
      id: string
    }

  // Reasoning blocks:
  | {
      type: 'reasoning-start'
      providerMetadata?: SharedProviderMetadata
      id: string
    }
  | {
      type: 'reasoning-delta'
      id: string
      providerMetadata?: SharedProviderMetadata
      delta: string
    }
  | {
      type: 'reasoning-end'
      id: string
      providerMetadata?: SharedProviderMetadata
    }

  // Tool calls and results:
  | {
      type: 'tool-input-start'
      id: string
      toolName: string
      providerMetadata?: SharedProviderMetadata
      providerExecuted?: boolean
      dynamic?: boolean
      title?: string
    }
  | {
      type: 'tool-input-delta'
      id: string
      delta: string
      providerMetadata?: SharedProviderMetadata
    }
  | {
      type: 'tool-input-end'
      id: string
      providerMetadata?: SharedProviderMetadata
    }
  | LanguageModelToolApprovalRequest
  | LanguageModelToolCall
  | LanguageModelToolResult
  | LanguageModelCustomContent

  // Files and sources:
  | LanguageModelFile
  | LanguageModelReasoningFile
  | LanguageModelSource

  // stream start event with warnings for the call, e.g. unsupported settings:
  | {
      type: 'stream-start'
      warnings: Array<SharedWarning>
    }

  // metadata for the response.
  // separate stream part so it can be sent once it is available.
  | ({ type: 'response-metadata' } & LanguageModelResponseMetadata)

  // metadata that is available after the stream is finished:
  | {
      type: 'finish'
      usage: LanguageModelUsage
      finishReason: LanguageModelFinishReason
      providerMetadata?: SharedProviderMetadata
    }

  // raw chunks if enabled
  | {
      type: 'raw'
      rawValue: unknown
    }

  // error parts are streamed, allowing for multiple errors
  | {
      type: 'error'
      error: unknown
    }
