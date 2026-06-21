import { treaty } from '@elysia/eden'
import type { WebServer } from '@/core/web-server'

export class ApiError extends Error {
  constructor(
    readonly status: number,
    readonly body: unknown
  ) {
    super(`API request failed (${status})`)
    this.name = 'ApiError'
  }
}

/**
 * Eden Treaty client for the server's `/api/*` surface.
 *
 * Request and response types flow end-to-end from the Elysia app type, so the
 * frontend no longer hand-copies backend response shapes. `import type` keeps the
 * server type-only (no server code is bundled into the SPA).
 */
const client = treaty<WebServer>(typeof window === 'undefined' ? 'http://localhost' : window.location.origin, {
  fetch: { credentials: 'same-origin' }
})

/** Typed `/api/*` accessor: `api.console.agents.get()`, `api.session.get()`, etc. */
export const api = client.api

/**
 * Unwrap a Treaty response for React Query: return `data`, or throw {@link ApiError}
 * carrying the server error body so {@link apiErrorMessage} can render it.
 *
 * Elysia merges `onError` return shapes into the inferred success type, so the
 * returned data union is narrowed with `Exclude<…, { error: unknown }>` to drop
 * those error envelopes and leave only the real success payload.
 */
export async function unwrap<R extends { data: unknown; error: unknown }>(
  promise: Promise<R>
): Promise<Exclude<NonNullable<R['data']>, { error: unknown }>> {
  const { data, error } = await promise
  if (error) {
    const treatyError = error as { status?: number; value?: unknown }
    throw new ApiError(typeof treatyError.status === 'number' ? treatyError.status : 500, treatyError.value ?? error)
  }

  return data as Exclude<NonNullable<R['data']>, { error: unknown }>
}

/** Extracts the most useful user-facing message from Treaty, Elysia, or generic thrown errors. */
export function apiErrorMessage(error: unknown): string {
  if (!error) return ''
  if (error instanceof ApiError) return errorBodyMessage(error.body) ?? error.message
  if (error instanceof Error) return error.message

  return errorBodyMessage(error) ?? String(error)
}

/** Reads common server error envelope shapes before falling back to formatted JSON. */
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

/** Narrows unknown error bodies without treating arrays as object envelopes. */
function isJsonObject(value: unknown): value is { [key: string]: unknown } {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}
