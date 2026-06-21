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

/**
 * Exa adapter — the only built-in that serves both capabilities. Search hits
 * `/search`, extraction hits `/contents`. Auth is the `x-api-key` header, and a
 * missing key makes the provider report unavailable (no key => `available()`
 * false), so the registry skips it during fallback instead of failing a call.
 */
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
    // Exa may populate any of several snippet fields per hit. Prefer the
    // query-relevant `highlights` (we asked for them), then a `summary`, then the
    // raw `text`, falling to '' so the normalized shape always has a snippet.
    // `slice(limit)` re-applies the cap defensively in case the API over-returns.
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
    // Exa returns content and per-URL failure in two parallel arrays (`results`
    // and `statuses`), keyed by url/id and not guaranteed to match the request
    // order. Index both by a normalized URL so we can re-join them back onto the
    // caller's exact input list below. `normalizeUrl` absorbs trailing-slash /
    // whitespace drift between what we sent and what Exa echoes back.
    const byUrl = new Map((data.results ?? []).map(result => [normalizeUrl(result.url ?? result.id ?? ''), result]))
    const errorByKey = new Map(
      (data.statuses ?? [])
        .filter(status => status.status && status.status !== 'success')
        .map(status => [normalizeUrl(status.id ?? ''), status.error?.tag ?? 'extract failed'])
    )
    // Project onto the input URLs so the result is 1:1 with the request (same
    // length and order the caller expects). A URL with no content row becomes a
    // per-URL error — the matching status tag if Exa reported one, else a generic
    // "no content returned" — rather than being dropped.
    return args.urls.map(url => {
      const key = normalizeUrl(url)
      const result = byUrl.get(key)
      if (result) return { url, title: result.title ?? '', text: result.text ?? '' }
      return { url, title: '', text: '', error: errorByKey.get(key) ?? 'no content returned' }
    })
  }
}
