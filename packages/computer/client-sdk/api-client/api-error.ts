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
  /** Stable machine code callers branch on; defaults to `api_error` when the response gave none. */
  readonly code: string
  readonly method: string
  readonly url: string
  /** Parsed error payload when available (JSON object or raw text); kept for diagnostics. */
  readonly body?: unknown

  constructor(init: ApiErrorInit) {
    super(init.message)
    // Set explicitly because subclassing Error loses the constructor name through
    // transpilation; callers and logs rely on `name === 'ApiError'`.
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
