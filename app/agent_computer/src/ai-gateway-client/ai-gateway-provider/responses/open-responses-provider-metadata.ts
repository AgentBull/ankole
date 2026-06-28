import type { openResponsesChunkSchema, OpenResponsesLogprobs } from './open-responses-api'
import type { InferSchema } from '@/ai-gateway-client/provider-utils'

type OpenResponsesChunk = InferSchema<typeof openResponsesChunkSchema>

type ResponsesOutputTextAnnotationProviderMetadata = Extract<
  OpenResponsesChunk,
  { type: 'response.output_text.annotation.added' }
>['annotation']

export type ResponsesProviderMetadata = {
  responseId: string | null | undefined
  logprobs?: Array<OpenResponsesLogprobs>
  serviceTier?: string
}

export type ResponsesReasoningProviderMetadata = {
  itemId: string
  reasoningEncryptedContent?: string | null
}

export type ResponsesCompactionProviderMetadata = {
  type: 'compaction'
  itemId: string
  encryptedContent?: string
}

export type ResponsesTextProviderMetadata = {
  itemId: string
  phase?: 'commentary' | 'final_answer' | null
  annotations?: Array<ResponsesOutputTextAnnotationProviderMetadata>
}

export type ResponsesSourceDocumentProviderMetadata =
  | {
      type: 'file_citation'
      fileId: string
      index: number
    }
  | {
      type: 'container_file_citation'
      fileId: string
      containerId: string
    }
  | {
      type: 'file_path'
      fileId: string
      index: number
    }
