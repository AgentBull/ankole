import { COMPUTER_SDK_VERSION } from '../version'
import type { FetchLike, WorkerTlsConfig } from '../types'
import { ApiError } from './api-error'
import { h2Request } from './h2-client'

export interface BaseClientConfig {
  baseUrl: string
  token?: string
  tls?: WorkerTlsConfig
  fetch?: FetchLike
  userAgent?: string
  /** When true, request lines are logged to stderr (mirrors the Vercel SDK debug switch). */
  debug?: boolean
}

export type QueryValue = string | number | boolean | undefined | null

/** Body shapes the SDK actually sends (JSON strings, gzip bytes, octet streams). */
export type RequestBody = string | Uint8Array | ArrayBuffer | Blob | ReadableStream<Uint8Array> | null

export interface RequestOptions {
  method?: string
  path: string
  query?: Record<string, QueryValue>
  headers?: Record<string, string>
  body?: RequestBody
  accept?: string
  contentType?: string
  signal?: AbortSignal
  /** When true, non-2xx responses are returned instead of thrown (caller inspects status). */
  noThrow?: boolean
  /**
   * Inter-frame read budget for a streaming (NDJSON) response. Set only for
   * `wait:true` command/shell streams, to that command's own timeout + grace —
   * the worker emits no keepalive frames mid-command, so a fixed value would
   * kill a legitimately quiet long command. Plain calls leave it unset and lean
   * on the h2 keepalive ping.
   */
  idleTimeoutMs?: number
}

/**
 * Thin shared HTTP layer. Like the Vercel SDK's `BaseClient`, it centralises
 * baseUrl joining, query building, auth + UA headers, fetch, and error mapping.
 * `APIClient`-style subclasses (control plane, worker) layer typed methods on top.
 */
export class BaseClient {
  protected readonly baseUrl: string
  protected readonly token: string | undefined
  protected readonly tls: WorkerTlsConfig | undefined
  protected readonly fetchImpl: FetchLike
  protected readonly customFetch: boolean
  protected readonly userAgent: string
  protected readonly debug: boolean

  constructor(config: BaseClientConfig) {
    this.baseUrl = config.baseUrl.replace(/\/+$/, '')
    this.token = config.token
    this.tls = config.tls
    this.customFetch = Boolean(config.fetch)
    this.fetchImpl = config.fetch ?? globalThis.fetch
    this.userAgent = config.userAgent ?? `agentbull/bullx-computer/${COMPUTER_SDK_VERSION}`
    this.debug = config.debug ?? false
  }

  protected buildUrl(path: string, query?: Record<string, QueryValue>): string {
    const url = new URL(`${this.baseUrl}${path.startsWith('/') ? path : `/${path}`}`)
    if (query) {
      for (const [key, value] of Object.entries(query)) {
        if (value !== undefined && value !== null) url.searchParams.set(key, String(value))
      }
    }
    return url.toString()
  }

  /**
   * Assembles the request headers: bearer auth (when a token is configured) and a
   * fixed User-Agent on every call, plus accept/content-type when given. Starts from
   * the caller's headers so per-request extras (e.g. `x-cwd`) survive.
   */
  protected buildHeaders(opts: RequestOptions): Headers {
    const headers = new Headers(opts.headers)
    headers.set('user-agent', this.userAgent)
    if (this.token) headers.set('authorization', `Bearer ${this.token}`)
    if (opts.accept) headers.set('accept', opts.accept)
    if (opts.contentType) headers.set('content-type', opts.contentType)
    return headers
  }

  /**
   * The single send path for every typed method. Builds the URL and headers, then
   * picks a transport: the in-house {@link h2Request} when mTLS is configured (the
   * worker speaks h2-over-mTLS and needs the streaming/keepalive behaviour fetch does
   * not give us), otherwise the host `fetch`. A caller-supplied `fetch` (tests, in-
   * process use) always wins over h2, even with TLS set, so it stays fully
   * overridable. Non-2xx responses throw an {@link ApiError} unless `noThrow` is set,
   * which the caller uses when a status like 404 is a normal result.
   */
  async request(opts: RequestOptions): Promise<Response> {
    const method = opts.method ?? 'GET'
    const url = this.buildUrl(opts.path, opts.query)
    const headers = this.buildHeaders(opts)
    if (this.debug) console.error(`[bullx-computer] ${method} ${url}`)

    const init = {
      method,
      headers,
      // Cast to the host's exact body type: bun and the app's DOM lib type `fetch`
      // bodies slightly differently, and a plain Uint8Array trips overload resolution.
      body: (opts.body ?? null) as RequestInit['body'],
      signal: opts.signal
    } as RequestInit & { tls?: { ca?: string[]; cert?: string; key?: string } }
    if (this.tls) init.tls = { ca: [this.tls.caCert], cert: this.tls.cert, key: this.tls.key }

    const response =
      this.tls && !this.customFetch
        ? await h2Request({
            method,
            url,
            headers,
            body: opts.body ?? null,
            signal: opts.signal,
            tls: this.tls,
            idleTimeoutMs: opts.idleTimeoutMs,
            debug: this.debug
          })
        : await this.fetchImpl(url, init)

    if (!response.ok && !opts.noThrow) throw await toApiError(response, method, url)
    return response
  }

  /** Issue a request and decode a JSON body. */
  async json<T>(opts: RequestOptions): Promise<T> {
    const response = await this.request({ accept: 'application/json', ...opts })
    return (await response.json()) as T
  }
}

/**
 * Best-effort decode of an error response into an {@link ApiError}. Tolerant by
 * design: the worker and control plane usually return a JSON `{ code, message }`,
 * but a proxy or a crash can return plain text or nothing, and the resulting error
 * must still be useful. Falls back through JSON → raw text → a status-only message.
 */
export async function toApiError(response: Response, method: string, url: string): Promise<ApiError> {
  let body: unknown
  let code: string | undefined
  // Default message if the body is empty or unreadable; overwritten below when the
  // payload carries something better.
  let message = `${method} ${url} failed with ${response.status}`
  try {
    const text = await response.text()
    if (text) {
      try {
        body = JSON.parse(text)
        const obj = body as { code?: unknown; error?: unknown; message?: unknown }
        // Prefer an explicit `code`; fall back to a legacy `error` string only when
        // `code` is absent. `message` overrides the default when present.
        if (typeof obj.code === 'string') code = obj.code
        if (typeof obj.error === 'string' && !code) code = obj.error
        if (typeof obj.message === 'string') message = obj.message
      } catch {
        // Not JSON: keep the raw text as both the body and the message.
        body = text
        message = text
      }
    }
  } catch {
    // Body could not even be read (e.g. the connection dropped mid-error); fall back
    // to the status-only message rather than masking the original failure.
  }
  return new ApiError({ status: response.status, code, message, method, url, body })
}
