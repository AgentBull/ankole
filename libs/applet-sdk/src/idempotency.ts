export type IdempotentOptions = {
  /** Retention window in seconds under the reserved `_idempotency:<key>` namespace (defaults to 86400s / 24h). */
  ttlSeconds?: number
}

export type IdempotencyClaimResult = { status: 'claimed'; claimId: string } | { status: 'replayed'; value: unknown }

export type IdempotencyStoreAdapter = {
  claim: (key: string, requestHash: string) => Promise<IdempotencyClaimResult>
  complete: (key: string, value: unknown, ttlSeconds: number, claimId: string) => Promise<unknown>
  release: (key: string, claimId: string) => Promise<unknown>
}

/**
 * Self-contained factory so both `@ankole/applet-sdk` tests and the serialized
 * Deno EdgeRuntime user-worker bootstrap share the exact same implementation.
 */
export function createIdempotencyExecutor(adapter: IdempotencyStoreAdapter) {
  const reservedScope = '_idempotency'
  const defaultTtlSeconds = 86_400
  const maxTtlSeconds = 7 * 86_400

  const cloneResult = <T>(value: T): T => {
    if (value === undefined || value === null || typeof value !== 'object') return value
    return JSON.parse(JSON.stringify(value)) as T
  }

  const unwrapStoredPayload = <T>(raw: unknown): T => {
    if (raw && typeof raw === 'object' && (raw as { __ankole_idempotent?: unknown }).__ankole_idempotent === 1) {
      const wrapped = raw as { hasUndefined?: boolean; value?: unknown }
      return wrapped.hasUndefined ? (undefined as T) : cloneResult(wrapped.value as T)
    }
    return cloneResult(raw as T)
  }

  const normalizeKey = async (rawKey: string): Promise<string> => {
    if (typeof rawKey !== 'string') {
      throw new TypeError('AnkoleRuntime.idempotent requires a non-empty string key')
    }
    const trimmed = rawKey.trim()
    if (!trimmed) {
      throw new TypeError('AnkoleRuntime.idempotent requires a non-empty string key')
    }
    const encoder = new TextEncoder()
    const prefixed = `${reservedScope}:${trimmed}`
    if (encoder.encode(prefixed).byteLength <= 255) return prefixed
    const digest = await crypto.subtle.digest('SHA-256', encoder.encode(trimmed))
    const hex = Array.from(new Uint8Array(digest), byte => byte.toString(16).padStart(2, '0')).join('')
    return `${reservedScope}:sha256:${hex}`
  }

  const resolveTtlSeconds = (options?: IdempotentOptions): number => {
    const raw = options?.ttlSeconds ?? defaultTtlSeconds
    if (typeof raw !== 'number' || !Number.isFinite(raw) || raw <= 0) {
      throw new TypeError('AnkoleRuntime.idempotent ttlSeconds must be a positive number')
    }
    return Math.min(Math.max(1, Math.round(raw)), maxTtlSeconds)
  }

  const encodeValue = (produced: unknown): { hasUndefined: true } | { hasUndefined: false; value: unknown } => {
    if (produced === undefined) {
      return { hasUndefined: true }
    }
    const encoded = JSON.stringify(produced)
    if (encoded === undefined) {
      throw new TypeError('AnkoleRuntime.idempotent result must be JSON serializable')
    }
    if (new TextEncoder().encode(encoded).byteLength > 60 * 1024) {
      throw new RangeError('AnkoleRuntime.idempotent result exceeds the 60 KiB state limit')
    }
    return { hasUndefined: false, value: JSON.parse(encoded) }
  }

  return async function idempotent<T>(key: string, fn: () => T | Promise<T>, options?: IdempotentOptions): Promise<T> {
    if (typeof fn !== 'function') {
      throw new TypeError('AnkoleRuntime.idempotent requires a callback function')
    }
    const storageKey = await normalizeKey(key)
    const ttlSeconds = resolveTtlSeconds(options)

    const claimOutcome = await adapter.claim(storageKey, storageKey)
    if (claimOutcome.status === 'replayed') {
      return unwrapStoredPayload<T>(claimOutcome.value)
    }

    let produced: T
    try {
      produced = await fn()
    } catch (error) {
      await adapter.release(storageKey, claimOutcome.claimId).catch(() => undefined)
      throw error
    }

    const serialized = encodeValue(produced)
    const envelope = serialized.hasUndefined
      ? { __ankole_idempotent: 1 as const, hasUndefined: true as const }
      : { __ankole_idempotent: 1 as const, value: serialized.value }
    await adapter.complete(storageKey, envelope, ttlSeconds, claimOutcome.claimId)
    return produced
  }
}
