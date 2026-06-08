import { delay } from '../utils/resolve-signal'
import { ApiError } from './api-error'

export interface RetryOptions {
  retries?: number
  minDelayMs?: number
  maxDelayMs?: number
  signal?: AbortSignal
  shouldRetry?: (error: unknown, attempt: number) => boolean
}

/** Default policy: retry network errors and 429/5xx, but never 4xx (except 429). */
function defaultShouldRetry(error: unknown): boolean {
  if (error instanceof ApiError) return error.status === 429 || error.status >= 500
  return true // network / fetch error
}

/** Run `fn` with exponential backoff. Used for transient control-plane calls. */
export async function withRetry<T>(fn: () => Promise<T>, opts: RetryOptions = {}): Promise<T> {
  const retries = opts.retries ?? 3
  const minDelay = opts.minDelayMs ?? 200
  const maxDelay = opts.maxDelayMs ?? 2000
  const shouldRetry = opts.shouldRetry ?? defaultShouldRetry

  let attempt = 0
  for (;;) {
    try {
      return await fn()
    } catch (error) {
      attempt += 1
      if (attempt > retries || !shouldRetry(error, attempt)) throw error
      await delay(Math.min(maxDelay, minDelay * 2 ** (attempt - 1)), opts.signal)
    }
  }
}
