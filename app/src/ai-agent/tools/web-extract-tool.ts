import { z } from 'zod'
import { appConfigService } from '@/config/app-configure'
import type { AgentTool, AgentToolResult } from '../core'
import { buildTool } from './build-tool'
import { WebExtractProviderConfig } from '../web/config'
import { type WebExtractResult, type WebProvider, WebProviderError } from '../web/provider'
import { webProviderRegistry } from '../web/registry'
import { wrapWebContent } from '@/security/external-content'

const WebExtractParams = z.object({
  urls: z
    .array(z.string().describe('An http(s) URL to extract.'))
    .min(1)
    .max(5)
    .describe('URLs to extract readable content from (max 5).')
})

interface WebExtractDetails {
  provider: string
  results: WebExtractResult[]
}

const DESCRIPTION = 'Fetch one or more URLs and return their readable text content (per-URL, partial failures allowed).'

function formatResults(results: WebExtractResult[]): string {
  if (results.length === 0) return 'No content extracted.'
  return results
    .map(result => {
      if (result.error) return `# ${result.url}\n[error] ${result.error}`
      const heading = result.title ? `# ${result.title}\n${result.url}` : `# ${result.url}`
      return `${heading}\n\n${wrapWebContent(result.text, 'web_fetch')}`
    })
    .join('\n\n---\n\n')
}

export function createWebExtractTool(): AgentTool<typeof WebExtractParams, WebExtractDetails> {
  return buildTool({
    name: 'web_extract',
    label: 'Web Extract',
    description: DESCRIPTION,
    schema: WebExtractParams,
    executionMode: 'parallel',
    isReadOnly: true,
    isDestructive: false,
    async execute(_toolCallId, params, signal): Promise<AgentToolResult<WebExtractDetails>> {
      const preferred = await appConfigService.get(WebExtractProviderConfig)
      const provider: WebProvider = await webProviderRegistry.select('extract', preferred)
      if (!provider.extract) {
        throw new WebProviderError(`provider ${provider.id} cannot extract`, {
          retryable: false,
          providerId: provider.id
        })
      }
      const results = await provider.extract({ urls: params.urls }, signal)
      return {
        content: [{ type: 'text', text: formatResults(results) }],
        details: { provider: provider.id, results }
      }
    }
  })
}
