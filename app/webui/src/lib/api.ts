export class ApiError extends Error {
  constructor(
    readonly status: number,
    readonly body: unknown
  ) {
    super(`API request failed (${status})`)
    this.name = 'ApiError'
  }
}

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

  const body = await safeJson(response)
  if (!response.ok) throw new ApiError(response.status, body)

  return body as T
}

async function safeJson(response: Response): Promise<unknown> {
  try {
    return await response.json()
  } catch {
    return null
  }
}
