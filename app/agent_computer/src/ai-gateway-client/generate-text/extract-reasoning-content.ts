import type { LanguageModelContent, LanguageModelReasoning } from '@/ai-gateway-client/provider'

export function extractReasoningContent(content: LanguageModelContent[]): string | undefined {
  const parts = content.filter((content): content is LanguageModelReasoning => content.type === 'reasoning')

  return parts.length === 0 ? undefined : parts.map(content => content.text).join('\n')
}
