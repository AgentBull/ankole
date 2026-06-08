import { z } from 'zod'
import { appConfigService } from '@/config/app-configure'
import type { AgentTool, AgentToolResult } from '../core'
import { buildTool } from './build-tool'
import { WebSearchProviderConfig } from '../web/config'
import { type WebProvider, WebProviderError, type WebSearchResult } from '../web/provider'
import { webProviderRegistry } from '../web/registry'

const WebSearchParams = z.object({
  query: z.string().min(1).describe('The search query.'),
  limit: z.number().int().min(1).max(20).describe('Maximum number of results (default 5).').optional()
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
  return buildTool({
    name: 'web_search',
    label: 'Web Search',
    description: DESCRIPTION,
    schema: WebSearchParams,
    executionMode: 'parallel',
    isReadOnly: true,
    isDestructive: false,
    async execute(_toolCallId, params, signal): Promise<AgentToolResult<WebSearchDetails>> {
      const preferred = await appConfigService.get(WebSearchProviderConfig)
      const provider: WebProvider = await webProviderRegistry.select('search', preferred)
      if (!provider.search) {
        throw new WebProviderError(`provider ${provider.id} cannot search`, {
          retryable: false,
          providerId: provider.id
        })
      }
      const results = await provider.search({ query: params.query, limit: params.limit }, signal)
      return {
        content: [{ type: 'text', text: formatResults(results) }],
        details: { provider: provider.id, results }
      }
    }
  })
}
