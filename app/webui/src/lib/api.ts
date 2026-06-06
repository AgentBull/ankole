export class ApiError extends Error {
  constructor(
    readonly status: number,
    readonly body: unknown
  ) {
    super(`API request failed (${status})`)
    this.name = 'ApiError'
  }
}

type JsonObject = { [key: string]: unknown }

export async function apiGet<T>(path: string): Promise<T> {
  return apiRequest<T>(path, { method: 'GET' })
}

export async function apiPost<T>(path: string, body: unknown = {}): Promise<T> {
  return apiRequest<T>(path, {
    method: 'POST',
    body: JSON.stringify(body),
    headers: { 'content-type': 'application/json' }
  })
}

export async function apiPut<T>(path: string, body: unknown): Promise<T> {
  return apiRequest<T>(path, {
    method: 'PUT',
    body: JSON.stringify(body),
    headers: { 'content-type': 'application/json' }
  })
}

export async function apiDelete<T>(path: string): Promise<T> {
  return apiRequest<T>(path, { method: 'DELETE' })
}

async function apiRequest<T>(path: string, init: RequestInit): Promise<T> {
  const response = await fetch(path, {
    credentials: 'same-origin',
    ...init,
    headers: {
      accept: 'application/json',
      ...(init.headers ?? {})
    }
  })

  const body = await readResponseBody(response)
  if (!response.ok) throw new ApiError(response.status, body)

  return body as T
}

async function readResponseBody(response: Response): Promise<unknown> {
  const text = await response.text()
  if (!text) return null

  try {
    return JSON.parse(text) as unknown
  } catch {
    return text
  }
}

export function apiErrorMessage(error: unknown): string {
  if (!error) return ''
  if (error instanceof ApiError) return errorBodyMessage(error.body) ?? error.message
  if (error instanceof Error) return error.message

  return errorBodyMessage(error) ?? String(error)
}

function errorBodyMessage(body: unknown): string | undefined {
  if (body == null) return undefined
  if (typeof body === 'string') return body
  if (isJsonObject(body)) {
    const error = body.error
    if (typeof error === 'string') return error
    if (isJsonObject(error) && typeof error.message === 'string') return error.message
    if (typeof body.message === 'string') return body.message
  }

  return JSON.stringify(body, null, 2)
}

function isJsonObject(value: unknown): value is JsonObject {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}
