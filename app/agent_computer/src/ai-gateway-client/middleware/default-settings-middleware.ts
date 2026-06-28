import type { LanguageModelCallOptions } from '@/ai-gateway-client/provider'
import type { LanguageModelMiddleware } from '../types'
import { mergeObjects } from '../util/merge-objects'

/**
 * Applies default settings for a language model.
 */
export function defaultSettingsMiddleware({
  settings
}: {
  settings: Partial<{
    maxOutputTokens?: LanguageModelCallOptions['maxOutputTokens']
    temperature?: LanguageModelCallOptions['temperature']
    stopSequences?: LanguageModelCallOptions['stopSequences']
    topP?: LanguageModelCallOptions['topP']
    topK?: LanguageModelCallOptions['topK']
    presencePenalty?: LanguageModelCallOptions['presencePenalty']
    frequencyPenalty?: LanguageModelCallOptions['frequencyPenalty']
    responseFormat?: LanguageModelCallOptions['responseFormat']
    seed?: LanguageModelCallOptions['seed']
    tools?: LanguageModelCallOptions['tools']
    toolChoice?: LanguageModelCallOptions['toolChoice']
    headers?: LanguageModelCallOptions['headers']
    providerOptions?: LanguageModelCallOptions['providerOptions']
  }>
}): LanguageModelMiddleware {
  return {
    transformParams: async ({ params }) => {
      return mergeObjects(settings, params) as LanguageModelCallOptions
    }
  }
}
