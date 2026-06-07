import { htmlToMarkdown } from '@mdream/js'
import desktop from 'top-user-agents/desktop'
import type { WebExtractArgs, WebExtractResult, WebProvider } from '../provider'

const UA_CACHE_TTL_MS = 6 * 60 * 60 * 1000
const FETCH_TIMEOUT_MS = 30_000
const MAX_CONTENT_CHARS = 50_000
const MAX_RESPONSE_BYTES = 5 * 1024 * 1024
const ACCEPT_HEADER = 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8'
const FALLBACK_UA =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'

const userAgents = desktop as readonly string[]
const uaCache = new Map<string, { ua: string; expiresAt: number }>()

/**
 * Pick a desktop UA for a domain, kept stable for 6h via an in-memory cache so
 * repeated fetches to the same host present a consistent browser identity.
 */
function sampleUserAgent(domain: string): string {
  const now = Date.now()
  const cached = uaCache.get(domain)
  if (cached && cached.expiresAt > now) return cached.ua
  const ua = userAgents[Math.floor(Math.random() * userAgents.length)] ?? FALLBACK_UA
  uaCache.set(domain, { ua, expiresAt: now + UA_CACHE_TTL_MS })
  return ua
}

function decodeEntities(value: string): string {
  return value
    .replace(/&amp;/g, '&')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&#0?39;/g, "'")
    .replace(/&nbsp;/g, ' ')
}

function extractTitle(html: string): string {
  const match = html.match(/<title[^>]*>([\s\S]*?)<\/title>/i)
  const raw = match?.[1]
  return raw ? decodeEntities(raw.replace(/\s+/g, ' ').trim()) : ''
}

function looksLikeHtml(body: string): boolean {
  const head = body.slice(0, 512).toLowerCase()
  return head.includes('<!doctype html') || head.includes('<html')
}

function truncate(text: string, max: number): string {
  return text.length > max ? `${text.slice(0, max)}\n…[truncated]` : text
}

function combineSignals(signal: AbortSignal | undefined, timeoutMs: number): AbortSignal {
  const timeout = AbortSignal.timeout(timeoutMs)
  return signal ? AbortSignal.any([signal, timeout]) : timeout
}

async function fetchOne(url: string, signal?: AbortSignal): Promise<WebExtractResult> {
  let domain: string
  try {
    domain = new URL(url).hostname
  } catch {
    return { url, title: '', text: '', error: 'invalid URL' }
  }
  try {
    const response = await fetch(url, {
      headers: { 'user-agent': sampleUserAgent(domain), accept: ACCEPT_HEADER },
      redirect: 'follow',
      signal: combineSignals(signal, FETCH_TIMEOUT_MS)
    })
    if (!response.ok) return { url, title: '', text: '', error: `HTTP ${response.status}` }
    const contentType = response.headers.get('content-type') ?? ''
    const declaredBytes = Number(response.headers.get('content-length') ?? '0')
    if (Number.isFinite(declaredBytes) && declaredBytes > MAX_RESPONSE_BYTES) {
      return { url, title: '', text: '', error: `response too large (${declaredBytes} bytes)` }
    }
    const isHtml = contentType.includes('html')
    const isTextual =
      isHtml ||
      contentType === '' ||
      contentType.startsWith('text/') ||
      contentType.includes('json') ||
      contentType.includes('xml')
    if (!isTextual) {
      return { url, title: '', text: '', error: `unsupported content type: ${contentType}` }
    }
    const body = await response.text()
    if (body.length > MAX_RESPONSE_BYTES) {
      return { url, title: '', text: '', error: 'response too large' }
    }
    if (isHtml || (contentType === '' && looksLikeHtml(body))) {
      // `clean` trims redundant markdown; `origin` resolves relative links.
      // (@mdream/js has no main-content isolation option — title is parsed separately.)
      const markdown = htmlToMarkdown(body, { origin: url, clean: true })
      return { url, title: extractTitle(body), text: truncate(markdown.trim(), MAX_CONTENT_CHARS) }
    }
    return { url, title: '', text: truncate(body, MAX_CONTENT_CHARS) }
  } catch (error) {
    return { url, title: '', text: '', error: error instanceof Error ? error.message : String(error) }
  }
}

/**
 * Built-in extract provider: Bun-native `fetch` + per-domain UA sampling +
 * mdream HTML→Markdown. Needs no API key, so it is always available and serves
 * as the last-resort extract fallback.
 */
export const webfetchProvider: WebProvider = {
  id: 'webfetch',
  supports: ['extract'],
  available() {
    return true
  },
  async extract(args: WebExtractArgs, signal?: AbortSignal): Promise<WebExtractResult[]> {
    return Promise.all(args.urls.map(url => fetchOne(url, signal)))
  }
}

/** Exposed for unit tests (UA 6h cache + title parsing). */
export const __webfetchInternals = { sampleUserAgent, extractTitle, looksLikeHtml, uaCache }
