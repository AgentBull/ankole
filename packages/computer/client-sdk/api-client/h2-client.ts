import * as http2 from 'node:http2'

import type { RequestBody } from './base-client'
import type { WorkerTlsConfig } from '../types'

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
    if (stopped || client.destroyed || client.closed || pongTimer) return
    let acked = false
    try {
      const sent = client.ping((error: Error | null) => {
        acked = true
        clearPong()
        if (error) logTransport(debug, `h2 ping error ${label}: ${error.message}`)
      })
      if (!sent) return
    } catch {
      return
    }
    pongTimer = setTimeout(() => {
      pongTimer = null
      if (acked || stopped) return
      logTransport(debug, `h2 keepalive timeout ${label}: no PONG in ${KEEPALIVE_TIMEOUT_MS}ms; destroying session`)
      client.destroy(new Error(`h2 keepalive timeout: worker unreachable (${label})`))
    }, KEEPALIVE_TIMEOUT_MS)
    pongTimer.unref?.()
  }, KEEPALIVE_INTERVAL_MS)
  interval.unref?.()
  return () => {
    stopped = true
    clearInterval(interval)
    clearPong()
  }
}

export async function h2Request(opts: H2RequestOptions): Promise<Response> {
  const url = new URL(opts.url)
  const label = `${opts.method} ${url.pathname}`
  const client = await connect(url, opts.tls, opts.signal)
  const body = await bodyToBytes(opts.body)
  const headers = requestHeaders(url, opts.method, opts.headers, body)
  const stopKeepalive = startKeepalive(client, label, opts.debug)

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
    if (body && body.byteLength > 0) stream.end(body)
    else stream.end()

    stream.once('close', () => {
      if (!settled) {
        cleanup()
        closeClient()
        reject(new Error(`h2 stream closed before response: ${opts.method} ${url.toString()}`))
      }
    })
  })
}

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

function streamToBody(
  stream: http2.ClientHttp2Stream,
  client: http2.ClientHttp2Session,
  opts: StreamToBodyOptions
): ReadableStream<Uint8Array> {
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
        armIdle()
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

async function bodyToBytes(body: RequestBody): Promise<Uint8Array | null> {
  if (body === null) return null
  if (typeof body === 'string') return new TextEncoder().encode(body)
  if (body instanceof Uint8Array) return body
  if (body instanceof ArrayBuffer) return new Uint8Array(body)
  if (body instanceof Blob) return new Uint8Array(await body.arrayBuffer())
  if (body instanceof ReadableStream) return readStream(body)
  throw new Error('unsupported h2 request body')
}

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
