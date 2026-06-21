import { get, isNumber, isPlainObject, isString } from '@pleisto/active-support'
import type { JsonObject, JsonValue } from './db-schema'

/**
 * Shared JSON coercion helpers used wherever an arbitrary runtime value has to
 * become a durable `jsonb`-safe fact (projection rows, agent messages, event
 * envelopes).
 *
 * The store must contain durable JSON facts, not executable closures, binary
 * payloads, or values PostgreSQL `jsonb` cannot represent. These helpers are the
 * single guard for that across External Gateway, AIAgent, and projection code.
 */

/** Deep-coerce an arbitrary value into a `jsonb`-safe {@link JsonValue}, or `null` when it cannot be represented. */
export function toJsonValue(value: unknown): JsonValue | null {
  if (value === undefined) return null

  try {
    // The replacer strips everything `jsonb` cannot durably hold. Functions,
    // `undefined`, `bigint`, `symbol`, and binary blobs are dropped (returning
    // `undefined` removes the key or array slot); `Date` is frozen to an ISO
    // string so it round-trips as a stable value rather than `{}`.
    const serialized = JSON.stringify(value, (_key, nestedValue) => {
      if (
        typeof nestedValue === 'function' ||
        typeof nestedValue === 'undefined' ||
        typeof nestedValue === 'bigint' ||
        typeof nestedValue === 'symbol'
      ) {
        return undefined
      }

      if (nestedValue instanceof Date) return nestedValue.toISOString()
      if (isBinaryLike(nestedValue)) return undefined

      return nestedValue
    })

    // Re-parsing yields a plain detached value with no live references. The
    // `catch` covers the one input `JSON.stringify` rejects outright — a circular
    // structure — which becomes `null` rather than a thrown error here.
    return serialized === undefined ? null : (JSON.parse(serialized) as JsonValue)
  } catch {
    return null
  }
}

/** Coerce a value into a plain JSON object, returning `{}` when it is not object-shaped. */
export function toJsonObject(value: unknown): JsonObject {
  const json = toJsonValue(value)
  if (typeof json === 'object' && json !== null && !Array.isArray(json)) return json

  return {}
}

/** Coerce a value into a JSON array, returning `[]` when it is not an array. */
export function toJsonArray(value: unknown): JsonValue[] {
  const json = toJsonValue(value)
  return Array.isArray(json) ? json : []
}

/** Read a string at a dot path, or `undefined` when the value is missing or not a string. */
export function stringFromPath(object: Record<string, unknown>, path: string[]): string | undefined {
  const value = get(object, path.join('.'))
  return isString(value) ? value : undefined
}

/** Read a number at a dot path, or `undefined` when the value is missing or not a number. */
export function numberFromPath(object: Record<string, unknown>, path: string[]): number | undefined {
  const value = get(object, path.join('.'))
  return isNumber(value) ? value : undefined
}

/**
 * True when the value is a plain JSON object (not null, not an array).
 *
 * Single home for the `isJsonObject` guard that domain services previously each
 * re-declared. Returns a {@link JsonObject} type guard so callers can narrow
 * straight into the durable JSON value space.
 */
export function isJsonObject(value: unknown): value is JsonObject {
  return isPlainObject(value)
}

/** Narrow a value to a {@link JsonObject}, or `undefined` when it is not object-shaped. */
export function jsonObject(value: unknown): JsonObject | undefined {
  return isJsonObject(value) ? value : undefined
}

/** Deep-clone a {@link JsonObject}. JSON facts are structured-clone safe by construction. */
export function cloneJsonObject<T extends JsonObject>(value: T): T {
  return structuredClone(value)
}

/** True for binary containers (ArrayBuffer, Blob, any TypedArray/DataView) that have no faithful JSON form and so are dropped. */
function isBinaryLike(value: unknown): boolean {
  return value instanceof ArrayBuffer || value instanceof Blob || ArrayBuffer.isView(value)
}
