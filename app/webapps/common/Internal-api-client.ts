import type { JsonObject } from '@pleisto/active-support'

type InternalApiRequestOptions = {
  body?: JsonObject
  method?: 'GET' | 'POST' | 'PUT'
}

/** Sends a same-origin GET request to the session-backed internal SPA API. */
export async function internalApiGet<T>(path: string): Promise<T> {
  return internalApiRequest<T>(path, { method: 'GET' })
}

/** Sends a same-origin POST request to the session-backed internal SPA API. */
export async function internalApiPost<T>(path: string, body?: JsonObject): Promise<T> {
  return internalApiRequest<T>(path, { method: 'POST', body })
}

/** Sends a same-origin PUT request to the session-backed internal SPA API. */
export async function internalApiPut<T>(path: string, body?: JsonObject): Promise<T> {
  return internalApiRequest<T>(path, { method: 'PUT', body })
}

async function internalApiRequest<T>(path: string, options: InternalApiRequestOptions): Promise<T> {
  const headers = new Headers()
  const csrfToken = document.querySelector<HTMLMetaElement>('meta[name="csrf-token"]')?.content

  headers.set('accept', 'application/json')
  // Phoenix serves these endpoints from a browser session, so JSON requests
  // still need the CSRF token rendered into the HTML shell.
  if (csrfToken) headers.set('x-csrf-token', csrfToken)

  const body = options.body === undefined ? undefined : JSON.stringify(options.body)
  if (body) headers.set('content-type', 'application/json')

  const response = await fetch(path, {
    body,
    credentials: 'same-origin',
    headers,
    method: options.method ?? 'GET'
  })
  const payload = await readPayload(response)

  if (!response.ok) {
    throw new Error(errorText(payload) || `${response.status} ${response.statusText}`)
  }

  return payload as T
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
    return typeof value === 'string' ? value : JSON.stringify(value)
  }

  return typeof payload === 'string' ? payload : undefined
}
