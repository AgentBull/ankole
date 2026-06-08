/** Structured error thrown for any non-OK worker / control-plane response. */
export interface ApiErrorInit {
  status: number
  code?: string
  message: string
  method: string
  url: string
  body?: unknown
}

export class ApiError extends Error {
  readonly status: number
  readonly code: string
  readonly method: string
  readonly url: string
  readonly body?: unknown

  constructor(init: ApiErrorInit) {
    super(init.message)
    this.name = 'ApiError'
    this.status = init.status
    this.code = init.code ?? 'api_error'
    this.method = init.method
    this.url = init.url
    this.body = init.body
  }
}

/** Convenience guard for callers that want to branch on a specific error code. */
export function isApiError(value: unknown, code?: string): value is ApiError {
  return value instanceof ApiError && (code === undefined || value.code === code)
}
