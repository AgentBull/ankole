import type { LanguageModelToolChoice } from '@/ai-gateway-client/provider'
import type { ToolChoice } from '../types/language-model'

export function prepareToolChoice({
  toolChoice
}: {
  // use of any because it doesn't matter for tool choice preparation
  toolChoice: ToolChoice<any> | undefined
}): LanguageModelToolChoice {
  return toolChoice == null
    ? { type: 'auto' }
    : typeof toolChoice === 'string'
      ? { type: toolChoice }
      : { type: 'tool' as const, toolName: toolChoice.toolName as string }
}
