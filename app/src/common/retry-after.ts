export function retryAfterMsFromError(error: unknown): number | undefined {
  return retryAfterMsFromUnknown(error, new WeakSet<object>())
}

export function parseRetryAfterHeaders(headers: unknown, now = Date.now()): number | undefined {
  const retryAfterMs = headerValue(headers, 'retry-after-ms')
  if (retryAfterMs) {
    const trimmed = retryAfterMs.trim()
    const milliseconds = Number(trimmed)
    if (/^\d+(?:\.\d+)?$/.test(trimmed) && Number.isFinite(milliseconds)) return Math.max(0, milliseconds)
  }

  const retryAfter = headerValue(headers, 'retry-after')
  if (!retryAfter) return undefined
  const seconds = Number.parseFloat(retryAfter)
  if (Number.isFinite(seconds) && seconds >= 0) return seconds * 1000
  const retryAt = Date.parse(retryAfter)
  if (Number.isNaN(retryAt)) return undefined
  return Math.max(0, retryAt - now)
}

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
