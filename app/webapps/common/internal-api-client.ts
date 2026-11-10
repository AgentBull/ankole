import { arrayPath, deepString, recordValue, safeJsonParse, stringArg } from '@agentbull/active-support'
import { identityHeaders } from './browser-context'
import type { CreateClientConfig } from './api/generated/client.gen'

/**
 * A non-2xx response from the internal SPA API. The message keeps the
 * human-readable text that `requestErrorMessage` renders; `status` and
 * `payload` let callers branch on specific error contracts, such as the
 * sign-in endpoint's lockout responses.
 */
export class InternalAPIError extends Error {
  readonly status: number
  readonly payload: unknown

  constructor(status: number, statusText: string, payload: unknown) {
    super(errorText(payload) || `${status} ${statusText}`)
    this.name = 'InternalAPIError'
    this.status = status
    this.payload = payload
  }
}

// The generated SDK owns methods, paths and JSON types. Browser transport
// keeps the same session and error contracts for auth, setup and Pod.
export const createClientConfig: CreateClientConfig = config => ({
  ...config,
  credentials: 'same-origin',
  headers: { accept: 'application/vnd.api+json', 'content-type': 'application/vnd.api+json' },
  fetch: (async (input: RequestInfo | URL, init?: RequestInit) => {
    const request = new Request(input, init)
    for (const [name, value] of Object.entries(sessionHeaders())) {
      if (name !== 'accept-language' || !request.headers.has(name)) request.headers.set(name, value)
    }
    const response = await globalThis.fetch(request)
    if (!response.ok) {
      throw new InternalAPIError(response.status, response.statusText, await readPayload(response))
    }
    return response
  }) as typeof fetch
})

function sessionHeaders(): Record<string, string> {
  const lang = typeof document !== 'undefined' ? document.documentElement?.lang?.trim() : undefined
  return { 'x-csrf-token': csrfToken(), ...(lang ? { 'accept-language': lang } : {}), ...identityHeaders() }
}

/**
 * POSTs a form with the transport's session headers and error contract. `fetch` cannot report how much of a
 * request body has been sent, so an upload that shows progress goes through XMLHttpRequest.
 */
export function postFormWithProgress<T>(
  path: string,
  body: FormData,
  signal: AbortSignal,
  onProgress: (loaded: number, total: number) => void
): Promise<T> {
  return new Promise((resolve, reject) => {
    const request = new XMLHttpRequest()
    request.open('POST', path)
    for (const [name, value] of Object.entries(sessionHeaders())) request.setRequestHeader(name, value)
    request.upload.onprogress = event => onProgress(event.loaded, event.total)
    request.onload = () => {
      const payload = request.responseText ? safeJsonParse(request.responseText).unwrapOr(request.responseText) : {}
      if (request.status >= 200 && request.status < 300) resolve(payload as T)
      else reject(new InternalAPIError(request.status, request.statusText, payload))
    }
    request.onerror = () => reject(new TypeError('Failed to fetch'))
    request.onabort = () => reject(new DOMException('The upload was aborted', 'AbortError'))
    signal.addEventListener('abort', () => request.abort(), { once: true })
    // An unsent request fires no abort event, so a signal that is already aborted rejects here.
    if (signal.aborted) reject(new DOMException('The upload was aborted', 'AbortError'))
    else request.send(body)
  })
}

export function csrfToken(): string {
  const token = document.querySelector<HTMLMetaElement>('meta[name="csrf-token"]')?.content
  if (!token) throw new Error('CSRF token is missing from the browser shell')
  return token
}

async function readPayload(response: Response): Promise<unknown> {
  const text = await response.text()
  if (!text) return {}

  return safeJsonParse(text).unwrapOr(text)
}

function errorText(payload: unknown): string | undefined {
  const record = recordValue(payload)
  if (record && 'error' in record) {
    return stringArg(record, 'error') ?? deepString(record, ['error', 'message']) ?? JSON.stringify(record.error)
  }

  // A JSON:API error document: the first error gives the text.
  const first = recordValue(arrayPath(record, ['errors'])[0])
  if (first) {
    return stringArg(first, 'detail') ?? stringArg(first, 'title')
  }

  return typeof payload === 'string' ? payload : undefined
}
