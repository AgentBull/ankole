/** JSON value shape accepted by the Phoenix setup/auth APIs. */
export type JsonValue = null | boolean | number | string | JsonValue[] | { [key: string]: JsonValue }
export type JsonObject = { [key: string]: JsonValue }

type RequestOptions = {
  body?: JsonValue
  method?: 'GET' | 'POST' | 'PUT' | 'DELETE'
}

/** Sends a same-origin GET request and returns the decoded JSON payload. */
export async function apiGet<T>(path: string): Promise<T> {
  return apiRequest<T>(path, { method: 'GET' })
}

/** Sends a same-origin POST request with Phoenix CSRF headers. */
export async function apiPost<T>(path: string, body?: JsonValue): Promise<T> {
  return apiRequest<T>(path, { method: 'POST', body })
}

/** Sends a same-origin PUT request with Phoenix CSRF headers. */
export async function apiPut<T>(path: string, body?: JsonValue): Promise<T> {
  return apiRequest<T>(path, { method: 'PUT', body })
}

/** Sends a same-origin DELETE request with Phoenix CSRF headers. */
export async function apiDelete<T>(path: string): Promise<T> {
  return apiRequest<T>(path, { method: 'DELETE' })
}

/** Converts caught request failures into UI-safe text. */
export function apiErrorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}

async function apiRequest<T>(path: string, options: RequestOptions): Promise<T> {
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
