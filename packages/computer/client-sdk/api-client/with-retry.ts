import { delay } from '../utils/resolve-signal'
import { ApiError } from './api-error'

export interface RetryOptions {
  retries?: number
  minDelayMs?: number
  maxDelayMs?: number
  signal?: AbortSignal
  shouldRetry?: (error: unknown, attempt: number) => boolean
}

/**
 * Default policy: retry what is plausibly transient, not what the caller did wrong.
 * A reached-but-failed request only retries on 429 (rate limit) or 5xx (server
 * fault); any other 4xx is the caller's error and would just fail again. A non-
 * {@link ApiError} means the request never got a response at all (connection reset,
 * DNS, TLS) and is retried — these are exactly the blips a redeploy or rebind
 * causes.
 */
function defaultShouldRetry(error: unknown): boolean {
  if (error instanceof ApiError) return error.status === 429 || error.status >= 500
  return true // network / fetch error
}

/**
 * Runs `fn`, retrying transient failures with exponential backoff. Used for the
 * control-plane resolve call, which can flap during deploys.
 *
 * Backoff is deterministic (`minDelay·2^n`, capped at `maxDelay`) with no jitter:
 * the SDK fans out one agent at a time, not a thundering herd, so the added
 * complexity of jitter buys little here. `signal` makes the wait itself abortable so
 * a cancelled caller does not sit out the backoff.
 */
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
      // `attempt` counts failures so far; stop once it passes the retry budget or
      // the policy says this error is not worth retrying.
      attempt += 1
      if (attempt > retries || !shouldRetry(error, attempt)) throw error
      await delay(Math.min(maxDelay, minDelay * 2 ** (attempt - 1)), opts.signal)
    }
  }
}
