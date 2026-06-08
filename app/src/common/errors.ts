import { z } from 'zod'

/**
 * Map an unknown thrown value to an HTTP status code. Shared by route handlers
 * (setup / console) so the same mapping isn't copied per module.
 */
export function statusFromError(error: unknown): number {
  if (error instanceof z.ZodError) return 422
  if (typeof error === 'object' && error && 'status' in error && typeof error.status === 'number') return error.status
  return 500
}
