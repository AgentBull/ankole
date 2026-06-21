import { appConfigService } from '@/config/app-configure'
import { WebJinaApiKey } from '../config'
import { requestJson } from '../http'
import type { WebExtractArgs, WebExtractResult, WebProvider } from '../provider'

const READER_URL = 'https://r.jina.ai/'

interface JinaResponse {
  data?: { title?: string; url?: string; content?: string }
}

/**
 * Extracts one URL via Jina Reader. The Bearer key is attached only when present
 * so the keyless (lower-rate-limit) path still works. Catches any failure and
 * returns it as the per-URL `error` field instead of throwing, so one bad URL in
 * a batch does not fail the others (see `extract` fan-out below).
 */
async function fetchOne(url: string, key: string | undefined, signal?: AbortSignal): Promise<WebExtractResult> {
  const headers: Record<string, string> = { 'content-type': 'application/json', accept: 'application/json' }
  if (key) headers.authorization = `Bearer ${key}`
  try {
    const data = await requestJson<JinaResponse>('jina', READER_URL, {
      method: 'POST',
      headers,
      body: JSON.stringify({ url }),
      signal
    })
    return { url, title: data.data?.title ?? '', text: data.data?.content ?? '' }
  } catch (error) {
    return { url, title: '', text: '', error: error instanceof Error ? error.message : String(error) }
  }
}

/**
 * Jina Reader extract provider. Keyless usage works at a lower rate limit, so it
 * is always available; a configured key raises the limit.
 */
export const jinaProvider: WebProvider = {
  id: 'jina',
  supports: ['extract'],
  available() {
    return true
  },
  async extract(args: WebExtractArgs, signal?: AbortSignal): Promise<WebExtractResult[]> {
    const key = await appConfigService.get(WebJinaApiKey)
    // Unbounded fan-out is fine here (unlike webfetch): every request goes to
    // Jina's own gateway, not to the target sites, so there is no third-party host
    // to overwhelm — only Jina's own rate limit, which the key/keyless tier sets.
    // The caller already caps `urls` at 5 (web_extract tool schema).
    return Promise.all(args.urls.map(url => fetchOne(url, key, signal)))
  }
}
