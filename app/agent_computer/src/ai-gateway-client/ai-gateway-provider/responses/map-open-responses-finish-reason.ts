import type { LanguageModelFinishReason } from '@/ai-gateway-client/provider'

export function mapOpenResponsesFinishReason({
  finishReason,
  hasFunctionCall
}: {
  finishReason: string | null | undefined
  // flag that checks if there have been client-side tool calls (not executed by provider)
  hasFunctionCall: boolean
}): LanguageModelFinishReason['unified'] {
  switch (finishReason) {
    case undefined:
    case null:
      return hasFunctionCall ? 'tool-calls' : 'stop'
    case 'max_output_tokens':
      return 'length'
    case 'content_filter':
      return 'content-filter'
    default:
      return hasFunctionCall ? 'tool-calls' : 'other'
  }
}
