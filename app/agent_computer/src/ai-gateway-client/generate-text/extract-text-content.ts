import type { LanguageModelContent, LanguageModelText } from '@/ai-gateway-client/provider'

export function extractTextContent(content: LanguageModelContent[]): string | undefined {
  const parts = content.filter((content): content is LanguageModelText => content.type === 'text')

  if (parts.length === 0) {
    return undefined
  }

  return parts.map(content => content.text).join('')
}
