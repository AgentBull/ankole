import { appConfigService } from '@/config/app-configure'
import { WebParallelApiKey } from '../config'
import { requestJson } from '../http'
import { type WebProvider, WebProviderError, type WebSearchArgs, type WebSearchResult } from '../provider'

const SEARCH_URL = 'https://api.parallel.ai/v1/search'

interface ParallelResponse {
  results?: Array<{ url?: string; title?: string; excerpts?: string[] }>
}

async function apiKey(): Promise<string | undefined> {
  return appConfigService.get(WebParallelApiKey)
}

export const parallelProvider: WebProvider = {
  id: 'parallel',
  supports: ['search'],
  async available() {
    return Boolean(await apiKey())
  },
  async unavailableReason() {
    return (await apiKey()) ? undefined : 'parallel api key not configured'
  },
  async search(args: WebSearchArgs, signal?: AbortSignal): Promise<WebSearchResult[]> {
    const key = await apiKey()
    if (!key) {
      throw new WebProviderError('parallel api key not configured', { retryable: false, providerId: 'parallel' })
    }
    const limit = args.limit ?? 5
    const data = await requestJson<ParallelResponse>('parallel', SEARCH_URL, {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-api-key': key },
      body: JSON.stringify({ objective: args.query, search_queries: [args.query], max_results: limit }),
      signal
    })
    return (data.results ?? []).slice(0, limit).map(result => ({
      title: result.title ?? '',
      url: result.url ?? '',
      snippet: Array.isArray(result.excerpts) ? result.excerpts.join(' ') : ''
    }))
  }
}
