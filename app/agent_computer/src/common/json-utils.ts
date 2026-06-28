import type { JsonObject } from '../actor_lane'
import { isPlainObject } from '@pleisto/active-support'

export function isRecord(value: unknown): value is JsonObject {
  return isPlainObject(value)
}

export function recordArg(args: JsonObject | undefined, key: string): JsonObject | undefined {
  const value = args?.[key]
  return isRecord(value) ? value : undefined
}

export function stringArg(args: JsonObject | undefined, key: string): string | undefined {
  const value = args?.[key]
  return typeof value === 'string' ? value : undefined
}

export function stringRecord(value: JsonObject | undefined): Record<string, string> {
  const out: Record<string, string> = {}
  for (const [key, nested] of Object.entries(value ?? {})) {
    if (typeof nested === 'string') out[key] = nested
  }
  return out
}

export function objectPath(source: unknown, path: string[]): JsonObject {
  const value = path.reduce<unknown>((current, key) => (isRecord(current) ? current[key] : undefined), source)
  return isRecord(value) ? value : {}
}

export function deepString(value: unknown, path: string[]): string | undefined {
  let current = value
  for (const key of path) {
    if (!isRecord(current)) return undefined
    current = current[key]
  }
  return typeof current === 'string' ? current : undefined
}

export function arrayPath(value: unknown, path: string[]): unknown[] {
  let current = value
  for (const key of path) {
    if (!isRecord(current)) return []
    current = current[key]
  }
  return Array.isArray(current) ? current : []
}

export function firstString(record: JsonObject, keys: string[]): string | undefined {
  for (const key of keys) {
    const value = record[key]
    if (typeof value === 'string' && value.length > 0) return value
  }
}

export function firstNumber(record: JsonObject, keys: string[]): number | undefined {
  for (const key of keys) {
    const value = record[key]
    if (typeof value === 'number' && Number.isFinite(value)) return value
  }
}

export function parseTimeMs(value: string | undefined): number | undefined {
  if (!value) return undefined
  const parsed = new Date(value)
  return Number.isNaN(parsed.getTime()) ? undefined : parsed.getTime()
}

export function safeJsonStringify(value: unknown): string {
  try {
    return JSON.stringify(value) ?? 'undefined'
  } catch {
    return String(value)
  }
}

export function lastNonEmpty(values: string[]): string | undefined {
  for (let index = values.length - 1; index >= 0; index -= 1) {
    const value = values[index]?.trim()
    if (value) return value
  }
}

export function jsonObject(value: unknown): JsonObject {
  const normalized = jsonValue(value)
  return isRecord(normalized) ? normalized : {}
}

export function jsonValue(value: unknown): unknown {
  if (value === null || value === undefined) return null
  if (Array.isArray(value)) return value.map(jsonValue)
  if (typeof value === 'string' || typeof value === 'number' || typeof value === 'boolean') return value
  if (isRecord(value)) return Object.fromEntries(Object.entries(value).map(([key, value]) => [key, jsonValue(value)]))
  return String(value)
}
