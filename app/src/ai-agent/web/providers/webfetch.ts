import { htmlToMarkdown } from '@mdream/js'
import { ms } from '@pleisto/active-support'
import desktop from 'top-user-agents/desktop'
import { all, createCombinedAbortSignal, withRetry } from '@/common/async'
import { WebProviderError, type WebExtractArgs, type WebExtractResult, type WebProvider } from '../provider'

const UA_CACHE_TTL_MS = ms('6h')
const FETCH_TIMEOUT_MS = ms('30s')
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

// Decodes only the handful of HTML entities that actually show up in <title>
// text. A full entity table is unnecessary here — titles are short and this keeps
// the helper dependency-free; mdream handles entities in the body separately.
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

// Sniffs whether a body is HTML when the server gave no content-type. Only the
// first 512 bytes are inspected — the doctype/<html> tag is always near the top,
// and scanning a multi-MB document for it would be wasteful.
function looksLikeHtml(body: string): boolean {
  const head = body.slice(0, 512).toLowerCase()
  return head.includes('<!doctype html') || head.includes('<html')
}

function truncate(text: string, max: number): string {
  return text.length > max ? `${text.slice(0, max)}\n…[truncated]` : text
}

/**
 * One fetch attempt. Throws `WebProviderError{retryable:true}` on a connection-level
 * failure (fetch reject) so `withRetry` retries transient network blips; returns a
 * terminal `WebExtractResult` for everything else, including HTTP error statuses (a
 * site returning 5xx is its own state, not a transient blip worth re-hammering).
 */
async function fetchOnce(url: string, domain: string, signal?: AbortSignal): Promise<WebExtractResult> {
  const combined = createCombinedAbortSignal(signal, FETCH_TIMEOUT_MS)
  try {
    let response: Response
    try {
      // Redirects are followed transparently by the runtime's fetch.
      // TODO: no SSRF guard here — neither the initial URL nor the redirect targets
      // are checked against private/link-local ranges (e.g. 127.0.0.1, 10.x, the
      // 169.254.169.254 cloud-metadata endpoint). Because the URL ultimately comes
      // from the model (and the model can be steered by injected web content), the
      // real fix is to resolve the host and reject private/loopback/link-local IPs
      // on the first request AND on every redirect hop. Today this path trusts the
      // caller-supplied URL.
      response = await fetch(url, {
        headers: { 'user-agent': sampleUserAgent(domain), accept: ACCEPT_HEADER },
        redirect: 'follow',
        signal: combined.signal
      })
    } catch (error) {
      throw new WebProviderError(error instanceof Error ? error.message : String(error), {
        retryable: true,
        providerId: 'webfetch'
      })
    }
    if (!response.ok) {
      return { url, title: '', text: '', error: `HTTP ${response.status}` }
    }
    const contentType = response.headers.get('content-type') ?? ''
    // First size gate: reject early on the declared Content-Length before reading
    // the body, so an honestly-large response is dropped without downloading it.
    const declaredBytes = Number(response.headers.get('content-length') ?? '0')
    if (Number.isFinite(declaredBytes) && declaredBytes > MAX_RESPONSE_BYTES) {
      return { url, title: '', text: '', error: `response too large (${declaredBytes} bytes)` }
    }
    // Only attempt textual formats. Binary types (pdf, images, archives) would
    // decode to garbage, so reject them with a clear per-URL error rather than
    // returning noise. An absent content-type ('') is allowed through and sniffed
    // from the body below, since some servers omit the header on real HTML.
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
    // Second size gate: Content-Length can lie or be absent (chunked responses),
    // so re-check the actual downloaded size. (Bound on chars, not bytes — close
    // enough as a cap, and cheaper than measuring encoded length.)
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
  } finally {
    combined.cleanup()
  }
}

/**
 * Extracts one URL with retry: validates the URL, resolves its host once (for UA
 * sampling), then runs `fetchOnce` under `withRetry`. The retry only kicks in for
 * the retryable network-blip errors `fetchOnce` raises; any other failure is
 * caught and returned as a per-URL `error` so a bad URL never throws out of the
 * batch. (Note the name: `fetchOne` is the retrying wrapper, `fetchOnce` is a
 * single attempt.)
 */
async function fetchOne(url: string, signal?: AbortSignal): Promise<WebExtractResult> {
  let domain: string
  try {
    domain = new URL(url).hostname
  } catch {
    return { url, title: '', text: '', error: 'invalid URL' }
  }
  try {
    return await withRetry(() => fetchOnce(url, domain, signal), {
      maxAttempts: 3,
      signal,
      isRetryable: error => error instanceof WebProviderError && error.retryable
    })
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
    // Bounded fan-out (≤3 concurrent) instead of an unbounded Promise.all, so a
    // 5-URL extract doesn't hit one host with 5 simultaneous fetches.
    return all(
      args.urls.map(url => () => fetchOne(url, signal)),
      3
    )
  }
}

/** Exposed for unit tests (UA 6h cache + title parsing). */
export const __webfetchInternals = { sampleUserAgent, extractTitle, looksLikeHtml, uaCache }
