import type { BrowserError, BrowserErrorCode } from './protocol'

export class BrowserDataError extends Error {
  readonly code: BrowserErrorCode
  readonly retryable: boolean
  readonly details: Record<string, unknown>

  constructor(
    code: BrowserErrorCode,
    message: string,
    options: { retryable?: boolean; details?: Record<string, unknown>; cause?: unknown } = {}
  ) {
    super(message, options.cause === undefined ? undefined : { cause: options.cause })
    this.name = 'BrowserDataError'
    this.code = code
    this.retryable = options.retryable ?? false
    this.details = options.details ?? {}
  }

  toBrowserError(): BrowserError {
    return {
      code: this.code,
      message: this.message,
      retryable: this.retryable,
      details: this.details
    }
  }
}

export function isFileNotFound(error: unknown): boolean {
  return error instanceof Error && 'code' in error && error.code === 'ENOENT'
}

export function browserError(error: unknown): BrowserError {
  if (error instanceof BrowserDataError) return error.toBrowserError()
  if (error instanceof DOMException && error.name === 'AbortError') {
    return { code: 'cancelled', message: error.message || 'operation cancelled', retryable: true, details: {} }
  }
  if (error instanceof Error) {
    return { code: 'internal', message: error.message, retryable: false, details: {} }
  }
  return { code: 'internal', message: String(error), retryable: false, details: {} }
}

export function invariant(
  condition: unknown,
  code: BrowserErrorCode,
  message: string,
  details?: Record<string, unknown>
): asserts condition {
  if (!condition) throw new BrowserDataError(code, message, { details })
}
