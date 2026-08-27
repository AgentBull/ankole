/**
 * Async control-flow primitives shared across the app.
 *
 * Ported/adapted from Claude Code's `utils/combinedAbortSignal.ts` and
 * `services/api/withRetry.ts`. Kept dependency-free and Bun-native.
 */
import { ms } from '@agentbull/active-support'
import { retryAfterMsFromError } from './retry-after'

// Upper bound on a server-supplied `Retry-After`. The header is advice from a
// party that does not know the caller's deadline, so it can lengthen a retry
// schedule but never past this.
const maxServerRetryAfterMs = ms('1m')

/**
 * How long to wait before the next attempt.
 *
 * A server hint raises the wait but never lowers it: backing off for less than
 * the server asked only earns another rejection. The hint is bounded because a
 * provider that asks for hours would otherwise park the caller past every
 * deadline that matters. Our own schedule is left alone — `maxMs` already
 * belongs to the caller.
 */
export function retrySleepMs(retryAfterMs: number | undefined, backoffMs: number): number {
  if (retryAfterMs === undefined) return backoffMs
  return Math.max(backoffMs, Math.min(retryAfterMs, maxServerRetryAfterMs))
}

/**
 * A combined `AbortSignal` that fires when `signal` aborts or `timeoutMs` elapses,
 * plus a `cleanup` the caller MUST invoke once the awaited work settles.
 *
 * Use this instead of `AbortSignal.timeout(ms)`: under Bun, `AbortSignal.timeout`
 * timers are finalized lazily and accumulate in native memory until they fire
 * (~2.4KB/call held for the full timeout). `setTimeout` + `clearTimeout` frees the
 * timer immediately on `cleanup`.
 */
export function createCombinedAbortSignal(
  signal: AbortSignal | null | undefined,
  timeoutMs: number
): { signal: AbortSignal; cleanup: () => void } {
  const controller = new AbortController()
  // Source already aborted: propagate its reason and hand back a no-op cleanup, so
  // we never arm a timer that would have to be torn down immediately.
  if (signal?.aborted) {
    controller.abort(signal.reason)
    return { signal: controller.signal, cleanup: () => {} }
  }

  const timer = setTimeout(() => {
    controller.abort(new DOMException(`Timed out after ${timeoutMs}ms`, 'TimeoutError'))
  }, timeoutMs)
  // Keep this timer ref'ed. It is currently used as the worker's hard text-turn
  // deadline, so it must fire even when the only other activity is native
  // ZMQ/fetch work that Bun may not count as a normal JS event-loop reference.
  // Source abort wins over the timeout: cancel the timer and forward the source's
  // reason so callers see the real cause rather than a synthetic TimeoutError.
  const onSourceAbort = (): void => {
    clearTimeout(timer)
    controller.abort(signal?.reason)
  }
  signal?.addEventListener('abort', onSourceAbort, { once: true })

  // Releasing the timer here is the entire point of this helper (see the doc note
  // on the Bun timeout leak). Callers must run it once the awaited work settles.
  const cleanup = (): void => {
    clearTimeout(timer)
    signal?.removeEventListener('abort', onSourceAbort)
  }
  return { signal: controller.signal, cleanup }
}

/**
 * Sleeps `ms`, resolving early (and notably *without* rejecting) when `signal`
 * aborts. Resolving on abort lets the retry loop decide what to do next on a
 * single code path, instead of wrapping every sleep in its own try/catch.
 */
function abortableSleep(ms: number, signal?: AbortSignal | null): Promise<void> {
  return new Promise<void>(resolve => {
    if (signal?.aborted) {
      resolve()
      return
    }
    const done = (): void => {
      clearTimeout(timer)
      signal?.removeEventListener('abort', done)
      resolve()
    }
    const timer = setTimeout(done, ms)
    timer.unref?.()
    signal?.addEventListener('abort', done, { once: true })
  })
}

// Process-wide rolling counter that de-correlates jitter across concurrent
// callers. Seeded randomly so separate processes don't march in lock-step, then
// advanced once per backoff to spread retries that would otherwise collide.
let jitterCounter = Math.floor(Math.random() * 1000)

/**
 * Exponential backoff with per-call de-correlation jitter, capped at `maxMs`.
 * `attempt` is 1-based.
 *
 * Jitter is added on top of (never subtracted from) the exponential term, so the
 * delay is always at least the base exponential and at most
 * `exponential * (1 + jitterRatio)`. Mixing the rolling counter into the random
 * draw spreads out many clients that hit a rate limit at the same instant, which
 * plain `Math.random()` jitter does less reliably (the thundering-herd case).
 */
export function jitteredBackoff(
  attempt: number,
  opts?: { baseMs?: number; jitterRatio?: number; maxMs?: number }
): number {
  const baseMs = opts?.baseMs ?? 250
  const maxMs = opts?.maxMs ?? 8000
  const jitterRatio = opts?.jitterRatio ?? 0.5
  const exponential = Math.min(baseMs * 2 ** Math.max(0, attempt - 1), maxMs)
  jitterCounter = (jitterCounter + 1) % 100000
  const decorrelated = (Math.random() + (jitterCounter % 997) / 997) % 1
  return exponential + decorrelated * jitterRatio * exponential
}

/**
 * Retry `fn` up to `maxAttempts` times while `isRetryable(error)` holds, with
 * abort-aware exponential backoff between attempts. Stops immediately when
 * `signal` aborts. Shared retry primitive for every external call (web/API/
 * provider tools) so the `retryable` classification each one already produces is
 * actually acted on, instead of forcing a wasteful model re-call.
 */
export async function withRetry<T>(
  fn: () => Promise<T>,
  opts: {
    maxAttempts?: number
    signal?: AbortSignal | null
    isRetryable?: (error: unknown) => boolean
    baseMs?: number
    maxMs?: number
  }
): Promise<T> {
  const maxAttempts = Math.max(1, opts.maxAttempts ?? 3)
  const isRetryable = opts.isRetryable ?? (() => false)
  let attempt = 0
  while (true) {
    attempt++
    try {
      return await fn()
    } catch (error) {
      // Give up immediately — without sleeping — on the last attempt, on abort, or
      // when the error is classified non-retryable. Re-throw the original error so
      // the caller sees the real failure, not a wrapper.
      if (attempt >= maxAttempts || opts.signal?.aborted || !isRetryable(error)) throw error
      await abortableSleep(retrySleepMs(retryAfterMsFromError(error), jitteredBackoff(attempt, opts)), opts.signal)
      // The sleep resolves (does not throw) on abort, so re-check here and bail
      // instead of burning another attempt after the caller has given up.
      if (opts.signal?.aborted) throw error
    }
  }
}
