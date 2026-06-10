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
}

const REQUEST_BODY_METHODS = new Set(['POST', 'PUT', 'PATCH'])
const CONNECT_TIMEOUT_MS = 15_000
const FORBIDDEN_H2_HEADERS = new Set(['connection', 'upgrade', 'keep-alive', 'proxy-connection'])

export async function h2Request(opts: H2RequestOptions): Promise<Response> {
  const url = new URL(opts.url)
  const client = await connect(url, opts.tls, opts.signal)
  const body = await bodyToBytes(opts.body)
  const headers = requestHeaders(url, opts.method, opts.headers, body)

  let settled = false
  return await new Promise<Response>((resolve, reject) => {
    const stream = client.request(headers)
    const cleanup = () => {
      opts.signal?.removeEventListener('abort', onAbort)
      stream.removeListener('error', onError)
    }
    const closeClient = () => {
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
        new Response(streamToBody(stream, client, opts.signal), {
          status,
          headers: toHeaders(responseHeaders)
        })
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

function streamToBody(
  stream: http2.ClientHttp2Stream,
  client: http2.ClientHttp2Session,
  signal?: AbortSignal
): ReadableStream<Uint8Array> {
  let settled = false
  let cleanup: (() => void) | undefined
  const closeClient = () => {
    if (!client.closed && !client.destroyed) client.close()
  }
  return new ReadableStream<Uint8Array>({
    start(controller) {
      cleanup = () => {
        signal?.removeEventListener('abort', onAbort)
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
      const onAbort = () => {
        stream.close(http2.constants.NGHTTP2_CANCEL)
        errorBody(signal?.reason ?? new Error('aborted'))
      }
      const onData = (chunk: Buffer | Uint8Array) => {
        if (settled) return
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
      signal?.addEventListener('abort', onAbort, { once: true })
      stream.on('data', onData)
      stream.once('end', onEnd)
      stream.once('error', onError)
      stream.once('close', onClose)
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
