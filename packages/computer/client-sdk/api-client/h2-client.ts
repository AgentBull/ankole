import * as http2 from 'node:http2'

import type { RequestBody } from './base-client'
import type { WorkerTlsConfig } from '../types'

// A hand-rolled HTTP/2 client over mTLS, used in place of `fetch` for worker
// calls. Two reasons it exists rather than reusing the platform fetch:
//   - Long-lived command streams. A `wait:true` command holds one response open
//     for the whole run (minutes for a `sleep 600`). h2 multiplexes many such
//     streams over a single TCP+TLS connection, and gives us per-stream control
//     (cancel one command without dropping the others).
//   - Liveness on a quiet stream. The worker emits no keepalive frames mid-
//     command, so a half-open connection to a dead worker is otherwise
//     invisible. This client adds its own h2 PING/PONG and an optional inter-
//     frame idle timer so a stalled call fails instead of hanging forever.
// One `h2Request` maps to one fresh session and one h2 stream; there is no
// connection pool. The cost (a TLS handshake per call) is accepted because the
// expensive calls are the long-lived streams, not high-frequency RPCs.

interface H2RequestOptions {
  method: string
  url: string
  headers: Headers
  body: RequestBody
  signal?: AbortSignal
  tls: WorkerTlsConfig
  /**
   * Inter-frame read budget for the response body. The worker streams no
   * keepalive frames during a `wait:true` command (it sits in a server-side
   * `timeout`, then emits the terminal line), so this MUST be set to the
   * command's own timeout + grace by the caller — never a fixed small value, or
   * a legitimately quiet long command (e.g. `sleep 600`) would be killed. Left
   * unset for plain request/response calls, which rely on the keepalive ping.
   */
  idleTimeoutMs?: number
  /** Mirror of the SDK debug switch: log transport-liveness events to stderr. */
  debug?: boolean
}

// Methods for which a zero-length body still needs an explicit `content-length: 0`
// header (some servers reject a POST/PUT/PATCH that omits it). GET/DELETE etc.
// carry no length header when bodyless.
const REQUEST_BODY_METHODS = new Set(['POST', 'PUT', 'PATCH'])
const CONNECT_TIMEOUT_MS = 15_000
// h2 PING/PONG liveness: a half-open connection to a dead worker (pod restart,
// network partition) is otherwise invisible — the request streams its headers
// and then hangs with no further frames. The ping detects it within roughly
// interval + timeout and destroys the session so the in-flight call errors.
// Unlike an inter-frame read timeout, this never misfires on a live worker that
// is legitimately quiet (its connection still answers PINGs).
const KEEPALIVE_INTERVAL_MS = 15_000
const KEEPALIVE_TIMEOUT_MS = 20_000
// Connection-specific HTTP/1 headers that HTTP/2 forbids. node:http2 throws if a
// request carries any of them, so they are stripped before the headers are sent.
// Callers should never set these, but the SDK accepts an arbitrary Headers bag,
// so the strip is a guard against a caller passing them through.
const FORBIDDEN_H2_HEADERS = new Set(['connection', 'upgrade', 'keep-alive', 'proxy-connection'])

function logTransport(debug: boolean | undefined, message: string): void {
  if (debug) console.error(`[bullx-computer] ${message}`)
}

/**
 * Drive an h2 PING every interval on a per-request session; if a PING is not
 * PONGed within the timeout, destroy the session so the in-flight stream errors
 * instead of hanging on a dead peer. Returns a stop() for the settle paths.
 */
function startKeepalive(client: http2.ClientHttp2Session, label: string, debug: boolean | undefined): () => void {
  let stopped = false
  let pongTimer: ReturnType<typeof setTimeout> | null = null
  const clearPong = () => {
    if (pongTimer) {
      clearTimeout(pongTimer)
      pongTimer = null
    }
  }
  const interval = setInterval(() => {
    // A non-null `pongTimer` means a previous PING is still awaiting its PONG, so
    // skip this tick: never have two pings outstanding, and never reset the
    // deadline of an in-flight one.
    if (stopped || client.destroyed || client.closed || pongTimer) return
    let acked = false
    try {
      const sent = client.ping((error: Error | null) => {
        acked = true
        clearPong()
        if (error) logTransport(debug, `h2 ping error ${label}: ${error.message}`)
      })
      // ping() returns false when the send buffer is full; treat that as "skip
      // this tick" rather than a failure — the next interval retries.
      if (!sent) return
    } catch {
      return
    }
    pongTimer = setTimeout(() => {
      pongTimer = null
      // `acked` closes the race where the PONG callback fired between scheduling
      // this timer and it running: if the PONG already arrived, do not kill a
      // healthy session.
      if (acked || stopped) return
      logTransport(debug, `h2 keepalive timeout ${label}: no PONG in ${KEEPALIVE_TIMEOUT_MS}ms; destroying session`)
      client.destroy(new Error(`h2 keepalive timeout: worker unreachable (${label})`))
    }, KEEPALIVE_TIMEOUT_MS)
    // unref both timers so a pending keepalive never by itself keeps the process
    // alive at shutdown.
    pongTimer.unref?.()
  }, KEEPALIVE_INTERVAL_MS)
  interval.unref?.()
  return () => {
    stopped = true
    clearInterval(interval)
    clearPong()
  }
}

/**
 * Performs one request over a fresh mTLS HTTP/2 session and resolves to a `fetch`-
 * shaped {@link Response}. The Response body is a {@link ReadableStream} backed by
 * the h2 stream, so a streaming (NDJSON) response is consumed incrementally rather
 * than buffered.
 *
 * The promise settles when the worker's response *headers* arrive (the `response`
 * event), not when the body finishes — the body keeps flowing afterwards through
 * the returned stream. `settled` tracks that boundary so a stream `close` that
 * happens before any headers (worker died mid-handshake) rejects, while a normal
 * close after headers does not.
 *
 * The whole session is dedicated to this one call: it is opened here and closed on
 * every settle path (resolve, reject, abort, error), since there is no pool to
 * return it to.
 */
export async function h2Request(opts: H2RequestOptions): Promise<Response> {
  const url = new URL(opts.url)
  const label = `${opts.method} ${url.pathname}`
  // Request body is buffered to bytes before the stream is opened, so the exact
  // content-length is known and sent up front. The SDK never needs request-side
  // streaming; only responses stream.
  const client = await connect(url, opts.tls, opts.signal)
  const body = await bodyToBytes(opts.body)
  const headers = requestHeaders(url, opts.method, opts.headers, body)
  const stopKeepalive = startKeepalive(client, label, opts.debug)

  // True once response headers have arrived. Distinguishes a stream that closes
  // mid-handshake (an error) from one that closes after a real response.
  let settled = false
  return await new Promise<Response>((resolve, reject) => {
    const stream = client.request(headers)
    const cleanup = () => {
      opts.signal?.removeEventListener('abort', onAbort)
      stream.removeListener('error', onError)
    }
    const closeClient = () => {
      stopKeepalive()
      if (!client.closed && !client.destroyed) client.close()
    }
    const onAbort = () => {
      cleanup()
      const reason = opts.signal?.reason ?? new Error('aborted')
      // RST_STREAM(CANCEL) tells the worker to stop producing this response (e.g.
      // kill the still-running command) instead of just dropping our read.
      stream.close(http2.constants.NGHTTP2_CANCEL)
      closeClient()
      reject(reason)
    }
    const onError = (error: Error) => {
      cleanup()
      closeClient()
      reject(error)
    }
    opts.signal?.addEventListener('abort', onAbort, { once: true })
    stream.once('error', onError)
    stream.once('response', responseHeaders => {
      // Headers arrived: the request half is done. Ownership of the session and
      // the keepalive now passes to streamToBody, which closes them when the body
      // ends. cleanup() here only drops the pre-response listeners.
      settled = true
      cleanup()
      const status = Number(responseHeaders[http2.constants.HTTP2_HEADER_STATUS] ?? 0)
      resolve(
        new Response(
          streamToBody(stream, client, {
            signal: opts.signal,
            idleTimeoutMs: opts.idleTimeoutMs,
            stopKeepalive,
            label,
            debug: opts.debug
          }),
          {
            status,
            headers: toHeaders(responseHeaders)
          }
        )
      )
    })
    // Write the buffered body (if any) and half-close the request stream. The
    // response can then start flowing.
    if (body && body.byteLength > 0) stream.end(body)
    else stream.end()

    // A close before `settled` means the stream ended without ever delivering
    // response headers — worker crash or reset during the handshake. The post-
    // headers handler (streamToBody) owns close from then on, so this only fires
    // for the pre-response case.
    stream.once('close', () => {
      if (!settled) {
        cleanup()
        closeClient()
        reject(new Error(`h2 stream closed before response: ${opts.method} ${url.toString()}`))
      }
    })
  })
}

/**
 * Opens one mTLS HTTP/2 session and resolves it only once it is actually usable.
 *
 * Mutual TLS: `ca` pins the worker's issuer, `cert`/`key` present the client
 * identity, and `rejectUnauthorized` keeps verification on so a worker with a bad
 * cert is refused. `servername` drives SNI when the host is an IP/alias.
 *
 * Readiness is taken from the `remoteSettings` event (the server's SETTINGS frame),
 * not a bare connect, because only then is the h2 session negotiated and writable.
 * ALPN is re-checked here: a TLS peer that did not negotiate `h2` would otherwise
 * leave us trying to speak HTTP/2 to an HTTP/1 endpoint, so a mismatch is failed
 * loudly rather than hanging on the first frame.
 */
function connect(url: URL, tls: WorkerTlsConfig, signal?: AbortSignal): Promise<http2.ClientHttp2Session> {
  return new Promise((resolve, reject) => {
    const client = http2.connect(url.origin, {
      ca: tls.caCert,
      cert: tls.cert,
      key: tls.key,
      ALPNProtocols: ['h2'],
      rejectUnauthorized: true,
      servername: url.hostname
    })
    // Bound the handshake itself: http2.connect does not time out on its own, so a
    // worker that accepts the TCP connection but never completes TLS/SETTINGS would
    // hang here without this.
    const timer = setTimeout(() => {
      cleanup()
      closeClient()
      reject(new Error(`h2 connect timeout: ${url.origin}`))
    }, CONNECT_TIMEOUT_MS)
    const closeClient = () => {
      if (!client.closed && !client.destroyed) client.close()
    }
    const cleanup = () => {
      clearTimeout(timer)
      signal?.removeEventListener('abort', onAbort)
      client.removeListener('error', onError)
      client.removeListener('remoteSettings', onReady)
    }
    const onAbort = () => {
      cleanup()
      closeClient()
      reject(signal?.reason ?? new Error('aborted'))
    }
    const onError = (error: Error) => {
      cleanup()
      closeClient()
      reject(error)
    }
    const onReady = () => {
      cleanup()
      if (client.alpnProtocol !== 'h2') {
        closeClient()
        reject(new Error(`worker did not negotiate h2; got ${String(client.alpnProtocol)}`))
        return
      }
      resolve(client)
    }
    signal?.addEventListener('abort', onAbort, { once: true })
    client.once('error', onError)
    client.once('remoteSettings', onReady)
  })
}

/**
 * Builds the outgoing header map for an h2 stream. The leading `:method`/`:path`/
 * `:scheme`/`:authority` entries are HTTP/2 *pseudo-headers* (the request line of
 * HTTP/1 carried as headers); they are required and must come from the URL, not the
 * caller. Caller headers are lower-cased (h2 requires lowercase field names) and the
 * connection-specific ones are dropped.
 */
function requestHeaders(url: URL, method: string, headers: Headers, body: Uint8Array | null): Record<string, string> {
  const result: Record<string, string> = {
    [http2.constants.HTTP2_HEADER_METHOD]: method,
    [http2.constants.HTTP2_HEADER_PATH]: `${url.pathname}${url.search}`,
    [http2.constants.HTTP2_HEADER_SCHEME]: url.protocol.replace(/:$/, ''),
    [http2.constants.HTTP2_HEADER_AUTHORITY]: url.host
  }
  headers.forEach((value, key) => {
    const normalized = key.toLowerCase()
    if (!FORBIDDEN_H2_HEADERS.has(normalized)) result[normalized] = value
  })
  if (body && body.byteLength > 0) result[http2.constants.HTTP2_HEADER_CONTENT_LENGTH] = String(body.byteLength)
  else if (REQUEST_BODY_METHODS.has(method)) result[http2.constants.HTTP2_HEADER_CONTENT_LENGTH] = '0'
  return result
}

/**
 * Converts incoming h2 response headers into a `fetch` {@link Headers}. Drops the
 * `:status` and other response pseudo-headers (keys starting with `:`), which do
 * not belong in a normal header bag — `:status` is read separately as the Response
 * status. A repeated header arrives as an array and is appended, not overwritten.
 */
function toHeaders(headers: http2.IncomingHttpHeaders): Headers {
  const result = new Headers()
  for (const [key, value] of Object.entries(headers)) {
    if (key.startsWith(':') || value === undefined) continue
    if (Array.isArray(value)) {
      for (const item of value) result.append(key, item)
    } else {
      result.set(key, String(value))
    }
  }
  return result
}

interface StreamToBodyOptions {
  signal?: AbortSignal
  idleTimeoutMs?: number
  stopKeepalive?: () => void
  label?: string
  debug?: boolean
}

/**
 * Adapts an h2 response stream into a `fetch`-style {@link ReadableStream}, and ties
 * the stream's whole lifetime to the underlying h2 session: when the body ends,
 * errors, or is cancelled, the session and its keepalive are torn down (there is no
 * pool to return them to).
 *
 * `settled` ensures end / error / abort / cancel each fire their teardown exactly
 * once, no matter which one wins the race. Backpressure flows the natural way: when
 * the consumer stops reading, the ReadableStream stops pulling and node:http2's own
 * flow control pauses the wire; if the consumer cancels, `cancel()` sends
 * RST_STREAM(CANCEL) so the worker stops producing.
 */
function streamToBody(
  stream: http2.ClientHttp2Stream,
  client: http2.ClientHttp2Session,
  opts: StreamToBodyOptions
): ReadableStream<Uint8Array> {
  // Guards every teardown path so the session is closed and the controller settled
  // only once.
  let settled = false
  let cleanup: (() => void) | undefined
  let idleTimer: ReturnType<typeof setTimeout> | null = null
  const clearIdle = () => {
    if (idleTimer) {
      clearTimeout(idleTimer)
      idleTimer = null
    }
  }
  const closeClient = () => {
    opts.stopKeepalive?.()
    if (!client.closed && !client.destroyed) client.close()
  }
  return new ReadableStream<Uint8Array>({
    start(controller) {
      cleanup = () => {
        clearIdle()
        opts.signal?.removeEventListener('abort', onAbort)
        stream.removeListener('data', onData)
        stream.removeListener('end', onEnd)
        stream.removeListener('error', onError)
        stream.removeListener('close', onClose)
      }
      const closeBody = () => {
        if (settled) return
        settled = true
        cleanup?.()
        closeClient()
        controller.close()
      }
      const errorBody = (error: unknown) => {
        if (settled) return
        settled = true
        cleanup?.()
        closeClient()
        controller.error(error)
      }
      // No inter-frame frame for idleTimeoutMs ms means the worker stopped
      // talking mid-stream (it streams no keepalive of its own); fail the body
      // so the caller errors instead of hanging. Reset on every frame.
      const armIdle = () => {
        if (!opts.idleTimeoutMs) return
        clearIdle()
        idleTimer = setTimeout(() => {
          logTransport(opts.debug, `h2 idle timeout ${opts.label ?? ''}: no frame in ${opts.idleTimeoutMs}ms`)
          stream.close(http2.constants.NGHTTP2_CANCEL)
          errorBody(new Error(`h2 idle timeout: worker stopped streaming after ${opts.idleTimeoutMs}ms`))
        }, opts.idleTimeoutMs)
        idleTimer.unref?.()
      }
      const onAbort = () => {
        stream.close(http2.constants.NGHTTP2_CANCEL)
        errorBody(opts.signal?.reason ?? new Error('aborted'))
      }
      const onData = (chunk: Buffer | Uint8Array) => {
        if (settled) return
        // A frame arrived, so reset the inter-frame idle clock before enqueuing.
        armIdle()
        // Re-view as a plain Uint8Array over the same bytes, honouring the chunk's
        // own offset/length window (a Node Buffer can be a slice of a larger pooled
        // ArrayBuffer; using the window avoids handing out the neighbouring bytes).
        controller.enqueue(new Uint8Array(chunk.buffer, chunk.byteOffset, chunk.byteLength))
      }
      const onEnd = () => {
        closeBody()
      }
      const onError = (error: Error) => {
        errorBody(error)
      }
      const onClose = () => {
        closeBody()
      }
      opts.signal?.addEventListener('abort', onAbort, { once: true })
      stream.on('data', onData)
      stream.once('end', onEnd)
      stream.once('error', onError)
      stream.once('close', onClose)
      armIdle()
    },
    cancel() {
      if (settled) return
      settled = true
      cleanup?.()
      stream.close(http2.constants.NGHTTP2_CANCEL)
      closeClient()
    }
  })
}

/**
 * Collapses any accepted request-body shape into a single byte buffer (or null for
 * no body). The request side does not stream — the body is fully materialised so its
 * exact content-length is known before the h2 stream opens. A `ReadableStream` body
 * is drained here rather than piped.
 */
async function bodyToBytes(body: RequestBody): Promise<Uint8Array | null> {
  if (body === null) return null
  if (typeof body === 'string') return new TextEncoder().encode(body)
  if (body instanceof Uint8Array) return body
  if (body instanceof ArrayBuffer) return new Uint8Array(body)
  if (body instanceof Blob) return new Uint8Array(await body.arrayBuffer())
  if (body instanceof ReadableStream) return readStream(body)
  throw new Error('unsupported h2 request body')
}

/** Drains a ReadableStream fully, then concatenates its chunks into one buffer. */
async function readStream(stream: ReadableStream<Uint8Array>): Promise<Uint8Array> {
  const chunks: Uint8Array[] = []
  let total = 0
  const reader = stream.getReader()
  try {
    for (;;) {
      const { done, value } = await reader.read()
      if (done) break
      chunks.push(value)
      total += value.byteLength
    }
  } finally {
    reader.releaseLock()
  }
  const output = new Uint8Array(total)
  let offset = 0
  for (const chunk of chunks) {
    output.set(chunk, offset)
    offset += chunk.byteLength
  }
  return output
}
