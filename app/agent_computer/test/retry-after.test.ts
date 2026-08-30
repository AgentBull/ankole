import { describe, expect, it } from 'bun:test'
import { retryAfterMsFromError } from '../src/common/retry-after'
import { retrySleepMs, withRetry } from '../src/common/async'

describe('@ankole/agent-computer Retry-After parsing', () => {
  const errorWith = (headers: Record<string, string>) => ({ response: { headers } })

  it('reads both header forms', () => {
    expect(retryAfterMsFromError(errorWith({ 'retry-after': '2' }))).toBe(2000)
    expect(retryAfterMsFromError(errorWith({ 'Retry-After': '0.5' }))).toBe(500)
    expect(retryAfterMsFromError(errorWith({ 'retry-after-ms': '1500' }))).toBe(1500)
  })

  it('prefers the millisecond header and falls back when it is malformed', () => {
    expect(retryAfterMsFromError(errorWith({ 'retry-after-ms': '250', 'retry-after': '9' }))).toBe(250)
    expect(retryAfterMsFromError(errorWith({ 'retry-after-ms': '250ms', 'retry-after': '9' }))).toBe(9000)
  })

  // A prefix parse reads these as 30s and 12s; `Date.parse` alone reads `12junk`
  // and `-5` as dates in 2001. Neither may become a sleep.
  it('refuses a value that is neither a plain delay nor an HTTP-date', () => {
    for (const value of ['30s', '12junk', '2 seconds', '', '  ', 'soon', '-5', '2026-08-27T10:00:00Z']) {
      expect(retryAfterMsFromError(errorWith({ 'retry-after': value }))).toBeUndefined()
    }
    // `99` stays a legal delay: the point is the shape, not the magnitude.
    expect(retryAfterMsFromError(errorWith({ 'retry-after': '99' }))).toBe(99_000)
  })

  it('converts an HTTP-date to a delay and never asks for a retry in the past', () => {
    const future = new Date(Date.now() + 30_000).toUTCString()
    const delay = retryAfterMsFromError(errorWith({ 'retry-after': future }))
    expect(delay).toBeGreaterThan(25_000)
    expect(delay).toBeLessThanOrEqual(30_000)

    expect(retryAfterMsFromError(errorWith({ 'retry-after': new Date(Date.now() - 60_000).toUTCString() }))).toBe(0)
    // The two obsolete forms RFC 9110 still requires a recipient to accept.
    expect(retryAfterMsFromError(errorWith({ 'retry-after': 'Wednesday, 21-Oct-15 07:28:00 GMT' }))).toBe(0)
    expect(retryAfterMsFromError(errorWith({ 'retry-after': 'Wed Oct 21 07:28:00 2015' }))).toBe(0)
  })

  it('finds the header wherever the SDK buried it, without looping on a cycle', () => {
    const cyclic: Record<string, unknown> = { cause: { headers: { 'retry-after': '3' } } }
    cyclic.self = cyclic
    expect(retryAfterMsFromError(cyclic)).toBe(3000)
    expect(retryAfterMsFromError(new Headers([['retry-after', '4']]))).toBeUndefined()
    expect(retryAfterMsFromError({ headers: new Headers([['retry-after', '4']]) })).toBe(4000)
  })
})

describe('@ankole/agent-computer withRetry backoff', () => {
  it('raises the wait to the server hint but never past the bound', () => {
    expect(retrySleepMs(undefined, 400)).toBe(400)
    expect(retrySleepMs(100, 400)).toBe(400)
    expect(retrySleepMs(2_000, 400)).toBe(2_000)
    expect(retrySleepMs(60_000, 400)).toBe(60_000)
    // An hour-long hint cannot hold the caller for an hour.
    expect(retrySleepMs(3_600_000, 400)).toBe(60_000)
  })

  it('waits for the server hint between attempts', async () => {
    const startedAt = Date.now()
    let attempts = 0

    await expect(
      withRetry(
        async () => {
          attempts += 1
          throw { response: { headers: { 'retry-after-ms': '150' } } }
        },
        { maxAttempts: 2, isRetryable: () => true, baseMs: 1, maxMs: 1 }
      )
    ).rejects.toBeDefined()

    expect(attempts).toBe(2)
    expect(Date.now() - startedAt).toBeGreaterThanOrEqual(140)
  })
})
