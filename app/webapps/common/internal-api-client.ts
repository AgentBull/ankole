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
    request.headers.set('x-csrf-token', csrfToken())
    const lang = typeof document !== 'undefined' ? document.documentElement?.lang?.trim() : undefined
    if (lang && !request.headers.has('accept-language')) request.headers.set('accept-language', lang)
    for (const [name, value] of Object.entries(identityHeaders())) request.headers.set(name, value)
    const response = await globalThis.fetch(request)
    if (!response.ok) {
      throw new InternalAPIError(response.status, response.statusText, await readPayload(response))
    }
    return response
  }) as typeof fetch
})

export function csrfToken(): string {
  const token = document.querySelector<HTMLMetaElement>('meta[name="csrf-token"]')?.content
  if (!token) throw new Error('CSRF token is missing from the browser shell')
  return token
}

async function readPayload(response: Response): Promise<unknown> {
  const text = await response.text()
  if (!text) return {}

  try {
    return JSON.parse(text)
  } catch {
    return text
  }
}

function errorText(payload: unknown): string | undefined {
  if (payload && typeof payload === 'object' && 'error' in payload) {
    const value = (payload as { error?: unknown }).error
    if (typeof value === 'string') return value
    if (value && typeof value === 'object' && 'message' in value && typeof value.message === 'string') {
      return value.message
    }
    return JSON.stringify(value)
  }

  // A JSON:API error document: the first error gives the text.
  if (payload && typeof payload === 'object' && 'errors' in payload) {
    const [first] = Array.isArray(payload.errors) ? payload.errors : []
    if (first && typeof first === 'object') {
      const { detail, title } = first as { detail?: unknown; title?: unknown }
      if (typeof detail === 'string') return detail
      if (typeof title === 'string') return title
    }
  }

  return typeof payload === 'string' ? payload : undefined
}
