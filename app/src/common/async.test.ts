import { describe, expect, it } from 'bun:test'
import { all, createCombinedAbortSignal, jitteredBackoff, withRetry } from './async'
import { parseRetryAfterHeaders } from './retry-after'

describe('all (bounded concurrency)', () => {
  it('returns results in input order while respecting the concurrency cap', async () => {
    let active = 0
    let peak = 0
    const thunk = (n: number) => async () => {
      active++
      peak = Math.max(peak, active)
      await Bun.sleep(10)
      active--
      return n
    }
    const results = await all([0, 1, 2, 3, 4].map(thunk), 2)
    expect(results).toEqual([0, 1, 2, 3, 4])
    expect(peak).toBeLessThanOrEqual(2)
    expect(await all([])).toEqual([])
  })

  it('rejects with the first thunk error', async () => {
    await expect(all([() => Promise.resolve(1), () => Promise.reject(new Error('boom'))], 2)).rejects.toThrow('boom')
  })
})

describe('createCombinedAbortSignal', () => {
  it('aborts on source or timeout, and cleanup prevents the Bun timeout leak', async () => {
    const source = new AbortController()
    const { signal, cleanup } = createCombinedAbortSignal(source.signal, 10_000)
    expect(signal.aborted).toBe(false)
    source.abort()
    expect(signal.aborted).toBe(true)
    cleanup()

    const timeout = createCombinedAbortSignal(undefined, 20)
    expect(timeout.signal.aborted).toBe(false)
    await Bun.sleep(50)
    expect(timeout.signal.aborted).toBe(true)
    timeout.cleanup()

    // After cleanup the timer must be cancelled: waiting past the timeout proves
    // the signal never fires, i.e. cleanup actually frees the pending timeout.
    const cleaned = createCombinedAbortSignal(undefined, 20)
    cleaned.cleanup()
    await Bun.sleep(50)
    expect(cleaned.signal.aborted).toBe(false)
  })
})

describe('jitteredBackoff', () => {
  it('grows exponentially within jitter bounds and caps at maxMs', () => {
    const d1 = jitteredBackoff(1, { baseMs: 100, maxMs: 1000 })
    expect(d1).toBeGreaterThanOrEqual(100)
    expect(d1).toBeLessThanOrEqual(150)

    const d3 = jitteredBackoff(3, { baseMs: 100, maxMs: 1000 })
    expect(d3).toBeGreaterThanOrEqual(400)
    expect(d3).toBeLessThanOrEqual(600)

    const capped = jitteredBackoff(20, { baseMs: 100, maxMs: 1000 })
    expect(capped).toBeGreaterThanOrEqual(1000)
    expect(capped).toBeLessThanOrEqual(1500)
  })
})

describe('withRetry', () => {
  it('retries retryable failures until success or maxAttempts', async () => {
    let successCalls = 0
    const result = await withRetry(
      async () => {
        successCalls++
        if (successCalls < 2) throw new Error('once')
        return 'ok'
      },
      { maxAttempts: 3, baseMs: 1, isRetryable: () => true }
    )
    expect(result).toBe('ok')
    expect(successCalls).toBe(2)

    let failureCalls = 0
    await expect(
      withRetry(
        async () => {
          failureCalls++
          throw new Error('temp')
        },
        { maxAttempts: 3, baseMs: 1, isRetryable: () => true }
      )
    ).rejects.toThrow('temp')
    expect(failureCalls).toBe(3)
  })

  // Both guards must short-circuit on the very first call: a non-retryable error
  // is fatal, and an already-aborted signal means the caller has given up — neither
  // should sleep or burn further attempts.
  it('does not back off for non-retryable or already-aborted work', async () => {
    let fatalCalls = 0
    await expect(
      withRetry(
        async () => {
          fatalCalls++
          throw new Error('fatal')
        },
        { maxAttempts: 3, baseMs: 1, isRetryable: () => false }
      )
    ).rejects.toThrow('fatal')
    expect(fatalCalls).toBe(1)

    let abortedCalls = 0
    const controller = new AbortController()
    controller.abort()
    await expect(
      withRetry(
        async () => {
          abortedCalls++
          throw new Error('x')
        },
        { maxAttempts: 5, baseMs: 1, signal: controller.signal, isRetryable: () => true }
      )
    ).rejects.toThrow('x')
    expect(abortedCalls).toBe(1)
  })

  // Proves the server's backoff hint flows end-to-end: a retryable error carrying
  // `Retry-After-Ms` makes the retry wait at least that long before the next try.
  it('honors Retry-After headers from retryable errors', async () => {
    // 0.02s expressed as the standard seconds form resolves to 20ms.
    expect(parseRetryAfterHeaders({ 'Retry-After': '0.02' })).toBe(20)

    let calls = 0
    const startedAt = Date.now()
    const result = await withRetry(
      async () => {
        calls++
        if (calls === 1) throw { headers: { 'Retry-After-Ms': '30' } }
        return 'ok'
      },
      { maxAttempts: 2, baseMs: 1, isRetryable: () => true }
    )

    expect(result).toBe('ok')
    expect(calls).toBe(2)
    expect(Date.now() - startedAt).toBeGreaterThanOrEqual(20)
  })
})
