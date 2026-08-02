import type { JsonObject as JSONObject } from '@agentbull/active-support'

type InternalAPIRequestOptions = {
  body?: JSONObject
  method?: 'GET' | 'POST' | 'PUT'
}

/** Sends a same-origin GET request to the session-backed internal SPA API. */
export async function internalAPIGet<T>(path: string): Promise<T> {
  return internalAPIRequest<T>(path, { method: 'GET' })
}

/** Sends a same-origin POST request to the session-backed internal SPA API. */
export async function internalAPIPost<T>(path: string, body?: JSONObject): Promise<T> {
  return internalAPIRequest<T>(path, { method: 'POST', body })
}

/** Sends a same-origin PUT request to the session-backed internal SPA API. */
export async function internalAPIPut<T>(path: string, body?: JSONObject): Promise<T> {
  return internalAPIRequest<T>(path, { method: 'PUT', body })
}

async function internalAPIRequest<T>(path: string, options: InternalAPIRequestOptions): Promise<T> {
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
