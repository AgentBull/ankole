import type { JsonObject as JSONObject } from '@agentbull/active-support'

/**
 * Extracts a server-requested backoff delay (in milliseconds) from a thrown
 * value, by hunting for rate-limit headers anywhere in the error's shape.
 *
 * Provider SDKs bury the response headers at different depths (on the error, on
 * `.response`, on `.cause`), so this walks the error graph rather than assuming
 * one layout. Returns `undefined` when no usable hint is found, which lets the
 * caller fall back to its own backoff schedule.
 */
export function retryAfterMsFromError(error: unknown): number | undefined {
  return retryAfterMsFromUnknown(error, new WeakSet<object>())
}

/**
 * Parses a backoff delay from a header bag, honoring both the standard
 * `Retry-After` and the non-standard `Retry-After-Ms` that some providers
 * (e.g. Anthropic/OpenAI) send for sub-second precision.
 *
 * `Retry-After-Ms` is preferred when present because it avoids the
 * second-granularity rounding of the standard header. The standard header is
 * read in both of its RFC forms: a delay in seconds, or an absolute HTTP-date.
 * All results are clamped to be non-negative so a stale clock or a past date
 * can never produce a negative sleep.
 */
function parseRetryAfterHeaders(headers: unknown): number | undefined {
  const retryAfterMs = headerValue(headers, 'retry-after-ms')
  if (retryAfterMs) {
    const milliseconds = nonNegativeNumber(retryAfterMs)
    if (milliseconds !== undefined) return milliseconds
  }

  const retryAfter = headerValue(headers, 'retry-after')
  if (!retryAfter) return undefined
  // Form 1: delay in seconds. Tried first because it is the common rate-limit case.
  const seconds = nonNegativeNumber(retryAfter)
  if (seconds !== undefined) return seconds * 1000
  // Form 2: absolute HTTP-date. Converted to a delay relative to `now`; a date in
  // the past clamps to 0 rather than asking the caller to retry in the past.
  return httpDateDelayMs(retryAfter)
}

/**
 * Reads a header as an absolute HTTP-date and returns the delay until it.
 *
 * `Date.parse` alone is far wider than the header allows: it reads `12junk` and
 * `-5` as real dates, which would turn a malformed value into a scheduled
 * sleep. All three date forms RFC 9110 permits start with a weekday name, so
 * requiring one keeps the accepted set close to the actual header. Anything
 * else — including an ISO instant, which this header does not carry — falls
 * back to the caller's own backoff schedule.
 */
function httpDateDelayMs(header: string): number | undefined {
  const trimmed = header.trim()
  if (!/^[A-Za-z]{3}/.test(trimmed)) return undefined
  const retryAt = Date.parse(trimmed)
  if (Number.isNaN(retryAt)) return undefined
  return Math.max(0, retryAt - Date.now())
}

/**
 * Parses a whole header value as a non-negative number.
 *
 * Both header forms must match completely: a prefix parse would turn a
 * malformed `30s` or `12junk` into a real sleep, and a bare `Number()` would
 * turn junk into 0. A value that does not match falls through to the next
 * accepted form, and finally to the caller's own backoff schedule.
 */
function nonNegativeNumber(header: string): number | undefined {
  const trimmed = header.trim()
  if (!/^\d+(?:\.\d+)?$/.test(trimmed)) return undefined
  const value = Number(trimmed)
  return Number.isFinite(value) ? value : undefined
}

/**
 * Depth-first walk of an error graph looking for the first node that carries a
 * usable `Retry-After` hint on its `.headers`.
 *
 * The `seen` set guards against cycles: provider errors routinely have
 * `error.cause === error` or other back-references, which would otherwise loop
 * forever. The `response`/`cause`/`error` keys cover the wrappers used by fetch,
 * native `Error.cause`, and SDK-specific envelopes respectively.
 */
function retryAfterMsFromUnknown(value: unknown, seen: WeakSet<object>): number | undefined {
  if (!value || typeof value !== 'object') return undefined
  if (seen.has(value)) return undefined
  seen.add(value)

  const record = value as JSONObject
  const fromHeaders = parseRetryAfterHeaders(record.headers)
  if (fromHeaders !== undefined) return fromHeaders

  for (const key of ['response', 'cause', 'error']) {
    const nested = retryAfterMsFromUnknown(record[key], seen)
    if (nested !== undefined) return nested
  }
  return undefined
}

/**
 * Reads one header value across the many container shapes a header bag can take:
 * a WHATWG `Headers` instance, a plain object (with case-insensitive lookup), an
 * array of values, or a `Map`-like object exposing `.get`.
 *
 * HTTP header names are case-insensitive but different libraries normalize them
 * differently, so the plain-object path tries the exact, lower, and upper forms
 * before falling back to a full case-insensitive scan.
 */
function headerValue(headers: unknown, key: string): string | undefined {
  if (!headers) return undefined
  if (typeof Headers !== 'undefined' && headers instanceof Headers) return headers.get(key) ?? undefined
  if (typeof headers === 'object') {
    const record = headers as JSONObject
    const direct =
      record[key] ?? record[key.toLowerCase()] ?? record[key.toUpperCase()] ?? findCaseInsensitive(record, key)
    if (typeof direct === 'string') return direct
    if (Array.isArray(direct)) return direct.find((value): value is string => typeof value === 'string')
    const get = record.get
    if (typeof get === 'function') {
      const value = get.call(headers, key)
      return typeof value === 'string' ? value : undefined
    }
  }
}

/**
 * Finds a plain-object header by case-insensitive name.
 */
function findCaseInsensitive(record: JSONObject, key: string): unknown {
  const lowerKey = key.toLowerCase()
  const entry = Object.entries(record).find(([candidate]) => candidate.toLowerCase() === lowerKey)
  return entry?.[1]
}
