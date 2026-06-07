import { Type } from 'typebox'
import { appConfigService } from '@/config/app-configure'
import type { AgentTool, AgentToolResult } from '../core'
import { WebSearchProviderConfig } from '../web/config'
import { type WebProvider, WebProviderError, type WebSearchResult } from '../web/provider'
import { webProviderRegistry } from '../web/registry'

const WebSearchParams = Type.Object({
  query: Type.String({ minLength: 1, description: 'The search query.' }),
  limit: Type.Optional(Type.Integer({ minimum: 1, maximum: 20, description: 'Maximum number of results (default 5).' }))
})

interface WebSearchDetails {
  provider: string
  results: WebSearchResult[]
}

const DESCRIPTION = 'Search the web and return a ranked list of results (title, url, snippet).'

function formatResults(results: WebSearchResult[]): string {
  if (results.length === 0) return 'No results found.'
  return results.map((result, index) => `${index + 1}. ${result.title}\n${result.url}\n${result.snippet}`).join('\n\n')
}

export function createWebSearchTool(): AgentTool<typeof WebSearchParams, WebSearchDetails> {
  return {
    name: 'web_search',
    label: 'Web Search',
    description: DESCRIPTION,
    parameters: WebSearchParams,
    executionMode: 'parallel',
    async execute(_toolCallId, params, signal): Promise<AgentToolResult<WebSearchDetails>> {
      const preferred = await appConfigService.get(WebSearchProviderConfig)
      const provider: WebProvider = await webProviderRegistry.select('search', preferred)
      if (!provider.search) {
        throw new WebProviderError(`provider ${provider.id} cannot search`, { retryable: false, providerId: provider.id })
      }
      const results = await provider.search({ query: params.query, limit: params.limit }, signal)
      return {
        content: [{ type: 'text', text: formatResults(results) }],
        details: { provider: provider.id, results }
      }
    }
  }
}
