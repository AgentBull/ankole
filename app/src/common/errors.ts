import { z } from 'zod'

/**
 * Domain failure with an HTTP-shaped status. One class serves every module's
 * "reject this request with a status + message" need; `code` carries an
 * optional machine-readable discriminator for clients that branch on it.
 */
export class DomainError extends Error {
  constructor(
    readonly status: number,
    message: string,
    readonly code?: string
  ) {
    super(message)
    this.name = 'DomainError'
  }
}

export interface StatusFromErrorOptions {
  /**
   * Defaults to 500 for HTTP route handlers. Pass `undefined` when callers need
   * to distinguish "no status found" from a concrete HTTP status.
   */
  fallback?: number
  /** Include `error.code` as a possible numeric/string HTTP status source. */
  includeCode?: boolean
}

/**
 * Map an unknown thrown value to an HTTP status code. Shared by route handlers
 * (setup / console) so the same mapping isn't copied per module.
 */
export function statusFromError(error: unknown): number
export function statusFromError(
  error: unknown,
  options: StatusFromErrorOptions & { fallback: undefined }
): number | undefined
export function statusFromError(error: unknown, options?: StatusFromErrorOptions): number | undefined {
  // Schema validation failures are always a client error: map them to 422
  // (Unprocessable Entity) regardless of any status the error might also carry.
  if (error instanceof z.ZodError) return 422
  const status = explicitStatusFromError(error, options?.includeCode ?? false)
  if (status !== undefined) return status
  // `'fallback' in options` (not a truthiness check) lets a caller pass an
  // explicit `fallback: undefined` to mean "tell me you found nothing" — distinct
  // from the default 500 used by HTTP route handlers.
  return options && 'fallback' in options ? options.fallback : 500
}

/**
 * Pulls an explicit HTTP status off an error-like object, checking the candidate
 * keys in priority order and returning the first that looks like a real status.
 *
 * `code` is only consulted when `includeCode` is set, because many libraries use
 * `code` for non-HTTP identifiers (Postgres `code`, Node `ERR_*`), so reading it
 * blindly would invent bogus statuses. The 100–599 range check is what rejects
 * those: a value like a Postgres SQLSTATE parses to a number but falls outside
 * the HTTP range and is ignored.
 */
function explicitStatusFromError(error: unknown, includeCode: boolean): number | undefined {
  if (!error || typeof error !== 'object') return undefined
  for (const key of includeCode ? ['status', 'statusCode', 'code'] : ['status', 'statusCode']) {
    const value = (error as Record<string, unknown>)[key]
    const parsed = typeof value === 'number' ? value : typeof value === 'string' ? Number.parseInt(value, 10) : NaN
    if (Number.isInteger(parsed) && parsed >= 100 && parsed <= 599) return parsed
  }
  return undefined
}
