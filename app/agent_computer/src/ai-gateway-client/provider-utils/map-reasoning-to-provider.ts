import type { LanguageModelCallOptions } from '@/ai-gateway-client/provider'

export function isCustomReasoning(
  reasoning: LanguageModelCallOptions['reasoning']
): reasoning is Exclude<LanguageModelCallOptions['reasoning'], 'provider-default' | undefined> {
  return reasoning !== undefined && reasoning !== 'provider-default'
}
