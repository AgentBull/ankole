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
  const limit = Math.max(1, Math.min(cap, thunks.length))
  const results: T[] = []
  let next = 0
  async function worker(): Promise<void> {
    while (next < thunks.length) {
      const index = next++
      results[index] = await thunks[index]!()
    }
  }
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
  if (signal?.aborted) {
    controller.abort(signal.reason)
    return { signal: controller.signal, cleanup: () => {} }
  }

  const timer = setTimeout(() => {
    controller.abort(new DOMException(`Timed out after ${timeoutMs}ms`, 'TimeoutError'))
  }, timeoutMs)
  timer.unref?.()
  const onSourceAbort = (): void => {
    clearTimeout(timer)
    controller.abort(signal?.reason)
  }
  signal?.addEventListener('abort', onSourceAbort, { once: true })

  const cleanup = (): void => {
    clearTimeout(timer)
    signal?.removeEventListener('abort', onSourceAbort)
  }
  return { signal: controller.signal, cleanup }
}

/** Sleep `ms`, resolving early (without rejecting) if `signal` aborts. */
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

let jitterCounter = Math.floor(Math.random() * 1000)

/**
 * Exponential backoff with per-call de-correlation jitter, capped at `maxMs`.
 * `attempt` is 1-based.
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
      if (attempt >= maxAttempts || opts.signal?.aborted || !isRetryable(error)) throw error
      const retryAfterMs = retryAfterMsFromError(error)
      const backoffMs = jitteredBackoff(attempt, opts)
      await abortableSleep(retryAfterMs === undefined ? backoffMs : Math.max(backoffMs, retryAfterMs), opts.signal)
      if (opts.signal?.aborted) throw error
    }
  }
}
