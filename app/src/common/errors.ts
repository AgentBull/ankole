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

/**
 * Map an unknown thrown value to an HTTP status code. Shared by route handlers
 * (setup / console) so the same mapping isn't copied per module.
 */
export function statusFromError(error: unknown): number {
  if (error instanceof z.ZodError) return 422
  if (typeof error === 'object' && error && 'status' in error && typeof error.status === 'number') return error.status
  return 500
}
