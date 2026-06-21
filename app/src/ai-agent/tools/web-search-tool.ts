import { z } from 'zod'
import { appConfigService } from '@/config/app-configure'
import type { AgentTool, AgentToolResult } from '../core'
import { buildTool } from './build-tool'
import { WebSearchProviderConfig } from '../web/config'
import { type WebProvider, WebProviderError, type WebSearchResult } from '../web/provider'
import { webProviderRegistry } from '../web/registry'
import { wrapWebContent } from '@/security/external-content'

// The schema doubles as the model's contract: every `.describe()` is text the
// model reads when deciding how to call the tool. `limit` is capped at 20 so a
// single search cannot flood the context window.
const WebSearchParams = z.object({
  query: z.string().min(1).describe('The search query.'),
  limit: z.number().int().min(1).max(20).describe('Maximum number of results (default 5).').optional()
})

// Structured echo of the run for logs/UI. `details` is not shown to the model;
// the model only sees the formatted `content` text.
interface WebSearchDetails {
  provider: string
  results: WebSearchResult[]
}

const DESCRIPTION = 'Search the web and return a ranked list of results (title, url, snippet).'

/**
 * Renders the result list into the plain text the model reads. Each snippet is
 * passed through `wrapWebContent` so untrusted web text is fenced in marked
 * boundaries — the model treats it as data, not as instructions to follow
 * (prompt-injection defense).
 */
function formatResults(results: WebSearchResult[]): string {
  if (results.length === 0) return 'No results found.'
  return results
    .map(
      (result, index) => `${index + 1}. ${result.title}\n${result.url}\n${wrapWebContent(result.snippet, 'web_search')}`
    )
    .join('\n\n')
}

/**
 * Builds the `web_search` tool the agent uses to look something up on the open
 * web. Pure read with no side effects, so it is marked read-only and may run in
 * parallel with other tool calls. The concrete search backend is chosen per call
 * from the provider registry, so swapping providers needs no change here.
 */
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
      // Operator config may name a preferred provider. When set, the registry
      // requires it and fails fast if it is missing/unavailable; when unset, it
      // falls back through the built-in priority order then any plugin provider.
      const preferred = await appConfigService.get(WebSearchProviderConfig)
      const provider: WebProvider = await webProviderRegistry.select('search', preferred)
      // Guards a provider registered for "extract" only. Thrown errors do not
      // crash the run: the loop turns them into a tool result the model reads.
      // Marked non-retryable because retrying the same provider cannot help.
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
