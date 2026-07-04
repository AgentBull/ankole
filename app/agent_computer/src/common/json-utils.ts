import type { JsonObject } from '../lanes/actor_lane'
import { isPlainObject } from '@pleisto/active-support'

/**
 * Narrows unknown values to plain JSON objects.
 */
export function isRecord(value: unknown): value is JsonObject {
  return isPlainObject(value)
}

/**
 * Reads one object field from optional JSON arguments.
 */
export function recordArg(args: JsonObject | undefined, key: string): JsonObject | undefined {
  const value = args?.[key]
  return isRecord(value) ? value : undefined
}

/**
 * Reads one string field from optional JSON arguments.
 */
export function stringArg(args: JsonObject | undefined, key: string): string | undefined {
  const value = args?.[key]
  return typeof value === 'string' ? value : undefined
}

/**
 * Copies only string fields from a JSON object.
 */
export function stringRecord(value: JsonObject | undefined): Record<string, string> {
  const out: Record<string, string> = {}
  for (const [key, nested] of Object.entries(value ?? {})) {
    if (typeof nested === 'string') out[key] = nested
  }
  return out
}

/**
 * Reads a nested object path, returning an empty object when absent.
 */
export function objectPath(source: unknown, path: string[]): JsonObject {
  const value = path.reduce<unknown>((current, key) => (isRecord(current) ? current[key] : undefined), source)
  return isRecord(value) ? value : {}
}

/**
 * Reads a nested string path from unknown JSON.
 */
export function deepString(value: unknown, path: string[]): string | undefined {
  let current = value
  for (const key of path) {
    if (!isRecord(current)) return undefined
    current = current[key]
  }
  return typeof current === 'string' ? current : undefined
}

/**
 * Reads a nested array path from unknown JSON.
 */
export function arrayPath(value: unknown, path: string[]): unknown[] {
  let current = value
  for (const key of path) {
    if (!isRecord(current)) return []
    current = current[key]
  }
  return Array.isArray(current) ? current : []
}

/**
 * Returns the first non-empty string among candidate keys.
 */
export function firstString(record: JsonObject, keys: string[]): string | undefined {
  for (const key of keys) {
    const value = record[key]
    if (typeof value === 'string' && value.length > 0) return value
  }
}

/**
 * Returns the first finite number among candidate keys.
 */
export function firstNumber(record: JsonObject, keys: string[]): number | undefined {
  for (const key of keys) {
    const value = record[key]
    if (typeof value === 'number' && Number.isFinite(value)) return value
  }
}

/**
 * Parses an optional timestamp string to epoch milliseconds.
 */
export function parseTimeMs(value: string | undefined): number | undefined {
  if (!value) return undefined
  const parsed = new Date(value)
  return Number.isNaN(parsed.getTime()) ? undefined : parsed.getTime()
}

/**
 * Stringifies unknown values without throwing on cyclic or unusual inputs.
 */
export function safeJsonStringify(value: unknown): string {
  try {
    return JSON.stringify(value) ?? 'undefined'
  } catch {
    return String(value)
  }
}

/**
 * Returns the last non-empty trimmed string from a list.
 */
export function lastNonEmpty(values: string[]): string | undefined {
  for (let index = values.length - 1; index >= 0; index -= 1) {
    const value = values[index]?.trim()
    if (value) return value
  }
}

/**
 * Normalizes unknown input to a JSON object shape.
 */
export function jsonObject(value: unknown): JsonObject {
  const normalized = jsonValue(value)
  return isRecord(normalized) ? normalized : {}
}

/**
 * Converts unknown values into JSON-safe primitives, arrays, and objects.
 */
export function jsonValue(value: unknown): unknown {
  if (value === null || value === undefined) return null
  if (Array.isArray(value)) return value.map(jsonValue)
  if (typeof value === 'string' || typeof value === 'number' || typeof value === 'boolean') return value
  if (isRecord(value)) return Object.fromEntries(Object.entries(value).map(([key, value]) => [key, jsonValue(value)]))
  return String(value)
}
