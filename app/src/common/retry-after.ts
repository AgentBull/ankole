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
 *
 * @param now - Injectable clock used to convert an HTTP-date into a relative
 *   delay; defaults to the current time and exists mainly for deterministic tests.
 */
export function parseRetryAfterHeaders(headers: unknown, now = Date.now()): number | undefined {
  const retryAfterMs = headerValue(headers, 'retry-after-ms')
  if (retryAfterMs) {
    // Accept only a bare integer/decimal; the regex rejects junk like `30s` so a
    // malformed value falls through to the standard header instead of being
    // silently treated as 0 by `Number`.
    const trimmed = retryAfterMs.trim()
    const milliseconds = Number(trimmed)
    if (/^\d+(?:\.\d+)?$/.test(trimmed) && Number.isFinite(milliseconds)) return Math.max(0, milliseconds)
  }

  const retryAfter = headerValue(headers, 'retry-after')
  if (!retryAfter) return undefined
  // Form 1: delay in seconds. Tried first because it is the common rate-limit case.
  const seconds = Number.parseFloat(retryAfter)
  if (Number.isFinite(seconds) && seconds >= 0) return seconds * 1000
  // Form 2: absolute HTTP-date. Converted to a delay relative to `now`; a date in
  // the past clamps to 0 rather than asking the caller to retry in the past.
  const retryAt = Date.parse(retryAfter)
  if (Number.isNaN(retryAt)) return undefined
  return Math.max(0, retryAt - now)
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

  const record = value as Record<string, unknown>
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
    const record = headers as Record<string, unknown>
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

function findCaseInsensitive(record: Record<string, unknown>, key: string): unknown {
  const lowerKey = key.toLowerCase()
  const entry = Object.entries(record).find(([candidate]) => candidate.toLowerCase() === lowerKey)
  return entry?.[1]
}
