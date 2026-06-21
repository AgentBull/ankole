/**
 * Async control-flow primitives shared across the app.
 *
 * Ported/adapted from Claude Code's `utils/combinedAbortSignal.ts`,
 * `utils/generators.ts`, and `services/api/withRetry.ts`. Kept dependency-free
 * and Bun-native.
 */
import { retryAfterMsFromError } from './retry-after'

/**
 * Run `thunks` with at most `cap` in flight at once, returning results in input
 * order (same contract as `Promise.all`, but concurrency-bounded). Rejects with
 * the first thunk error, like `Promise.all`.
 *
 * This is the bounded fan-out primitive for independent async work (e.g. fetching
 * several URLs). As more tools/providers are added, they share this instead of
 * each reinventing an unbounded `Promise.all`.
 */
export async function all<T>(thunks: ReadonlyArray<() => Promise<T>>, cap = Infinity): Promise<T[]> {
  if (thunks.length === 0) return []
  // Never spawn more workers than there is work, and always at least one.
  const limit = Math.max(1, Math.min(cap, thunks.length))
  const results: T[] = []
  // Shared cursor: every worker pulls the next index off `next`, so the pool stays
  // saturated regardless of how uneven the per-thunk durations are. Writing to
  // `results[index]` (not pushing) is what preserves input order.
  let next = 0
  async function worker(): Promise<void> {
    while (next < thunks.length) {
      const index = next++
      results[index] = await thunks[index]!()
    }
  }
  // The first rejecting thunk rejects this `Promise.all`, matching the documented
  // contract. In-flight siblings are not cancelled (there is no signal here); they
  // run to completion but their results are discarded.
  await Promise.all(Array.from({ length: limit }, () => worker()))
  return results
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
  // `unref` keeps a pending timeout from holding the process open during shutdown;
  // the optional-call guards runtimes where timer handles lack `unref`.
  timer.unref?.()
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
      // When the server told us how long to wait, never back off for *less* than
      // that; otherwise we'd just be rejected again. Take the larger of the
      // server's hint and our own jittered schedule.
      const retryAfterMs = retryAfterMsFromError(error)
      const backoffMs = jitteredBackoff(attempt, opts)
      await abortableSleep(retryAfterMs === undefined ? backoffMs : Math.max(backoffMs, retryAfterMs), opts.signal)
      // The sleep resolves (does not throw) on abort, so re-check here and bail
      // instead of burning another attempt after the caller has given up.
      if (opts.signal?.aborted) throw error
    }
  }
}
