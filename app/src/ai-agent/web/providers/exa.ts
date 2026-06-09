import { appConfigService } from '@/config/app-configure'
import { WebExaApiKey } from '../config'
import { normalizeUrl, requestJson } from '../http'
import {
  type WebExtractArgs,
  type WebExtractResult,
  type WebProvider,
  WebProviderError,
  type WebSearchArgs,
  type WebSearchResult
} from '../provider'

const SEARCH_URL = 'https://api.exa.ai/search'
const CONTENTS_URL = 'https://api.exa.ai/contents'

interface ExaSearchResponse {
  results?: Array<{ title?: string; url?: string; text?: string; highlights?: string[]; summary?: string }>
}

interface ExaContentsResponse {
  results?: Array<{ id?: string; url?: string; title?: string; text?: string }>
  statuses?: Array<{ id?: string; status?: string; error?: { tag?: string } }>
}

async function apiKey(): Promise<string | undefined> {
  return appConfigService.get(WebExaApiKey)
}

function requireKey(key: string | undefined): string {
  if (!key) throw new WebProviderError('exa api key not configured', { retryable: false, providerId: 'exa' })
  return key
}

export const exaProvider: WebProvider = {
  id: 'exa',
  supports: ['search', 'extract'],
  async available() {
    return Boolean(await apiKey())
  },
  async unavailableReason() {
    return (await apiKey()) ? undefined : 'exa api key not configured'
  },
  async search(args: WebSearchArgs, signal?: AbortSignal): Promise<WebSearchResult[]> {
    const key = requireKey(await apiKey())
    const limit = args.limit ?? 5
    const data = await requestJson<ExaSearchResponse>('exa', SEARCH_URL, {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-api-key': key },
      body: JSON.stringify({ query: args.query, type: 'auto', numResults: limit, contents: { highlights: true } }),
      signal
    })
    return (data.results ?? []).slice(0, limit).map(result => ({
      title: result.title ?? '',
      url: result.url ?? '',
      snippet:
        (Array.isArray(result.highlights) ? result.highlights.join(' ') : undefined) ??
        result.summary ??
        result.text ??
        ''
    }))
  },
  async extract(args: WebExtractArgs, signal?: AbortSignal): Promise<WebExtractResult[]> {
    const key = requireKey(await apiKey())
    const data = await requestJson<ExaContentsResponse>('exa', CONTENTS_URL, {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-api-key': key },
      body: JSON.stringify({ urls: args.urls, text: true }),
      signal
    })
    const byUrl = new Map((data.results ?? []).map(result => [normalizeUrl(result.url ?? result.id ?? ''), result]))
    const errorByKey = new Map(
      (data.statuses ?? [])
        .filter(status => status.status && status.status !== 'success')
        .map(status => [normalizeUrl(status.id ?? ''), status.error?.tag ?? 'extract failed'])
    )
    return args.urls.map(url => {
      const key = normalizeUrl(url)
      const result = byUrl.get(key)
      if (result) return { url, title: result.title ?? '', text: result.text ?? '' }
      return { url, title: '', text: '', error: errorByKey.get(key) ?? 'no content returned' }
    })
  }
}
