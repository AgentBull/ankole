import { jsonObject, type JsonObject } from '@agentbull/active-support'
import { sanitizeBinaryOutput, truncateUTF8Safe, utf8ByteLength } from '../../../common/text-sanitize'
import { redactText, redactionMarker, sensitiveKey } from '../../../common/content-redaction'

// Bound and redact runtime payloads before they become durable Job history.
const maxStringBytes = 16 * 1_024
const maxCollectionItems = 64
const maxMapKeyBytes = 256
const maxValueDepth = 8
const truncationMarker = '...[truncated]'

type SanitizeState = {
  redacted: boolean
  truncated: boolean
}

export function sanitizeTurnContent(value: JsonObject): { value: JsonObject } & SanitizeState {
  const state: SanitizeState = { redacted: false, truncated: false }
  return { value: jsonObject(sanitizeValue(value, state)), ...state }
}

function sanitizeValue(value: unknown, state: SanitizeState, depth = 0, key?: string): unknown {
  if (key && sensitiveKey(key)) {
    state.redacted = true
    return redactionMarker
  }
  if (depth > maxValueDepth) {
    state.truncated = true
    return truncationMarker
  }
  if (typeof value === 'string') return sanitizeString(value, state)
  if (typeof value === 'number' || typeof value === 'boolean' || value === null) return value
  if (Array.isArray(value)) {
    if (value.length > maxCollectionItems) state.truncated = true
    return value.slice(0, maxCollectionItems).map(item => sanitizeValue(item, state, depth + 1))
  }
  if (value && typeof value === 'object') {
    const entries = Object.entries(value as Record<string, unknown>)
    if (entries.length > maxCollectionItems) state.truncated = true
    return Object.fromEntries(
      entries
        .slice(0, maxCollectionItems)
        .map(([nestedKey, nested]) => [
          sanitizeMapKey(nestedKey, state),
          sanitizeValue(nested, state, depth + 1, nestedKey)
        ])
    )
  }
  return null
}

function sanitizeMapKey(value: string, state: SanitizeState): string {
  const key = sanitizeBinaryOutput(value)
  if (key !== value) state.truncated = true
  if (utf8ByteLength(key) <= maxMapKeyBytes) return key
  state.truncated = true
  return `${truncateUTF8Safe(key, maxMapKeyBytes - utf8ByteLength(truncationMarker))}${truncationMarker}`
}

function sanitizeString(value: string, state: SanitizeState): string {
  let text = sanitizeBinaryOutput(value)
  if (text !== value) state.truncated = true
  const redacted = redactText(text)
  if (redacted !== text) state.redacted = true
  text = redacted
  if (utf8ByteLength(text) <= maxStringBytes) return text
  state.truncated = true
  return truncateUTF8Window(text, maxStringBytes)
}

function truncateUTF8Window(value: string, maxBytes: number): string {
  if (utf8ByteLength(value) <= maxBytes) return value
  const available = Math.max(0, maxBytes - utf8ByteLength(truncationMarker))
  const headBytes = Math.ceil(available / 2)
  const tailBytes = available - headBytes
  return `${truncateUTF8Safe(value, headBytes)}${truncationMarker}${truncateUTF8SuffixSafe(value, tailBytes)}`
}

function truncateUTF8SuffixSafe(value: string, maxBytes: number): string {
  if (maxBytes <= 0) return ''
  if (utf8ByteLength(value) <= maxBytes) return value

  let low = 0
  let high = value.length
  let best = ''
  while (low <= high) {
    const middle = Math.floor((low + high) / 2)
    let start = middle
    const current = value.charCodeAt(start)
    const previous = value.charCodeAt(start - 1)
    if (current >= 0xdc00 && current <= 0xdfff && previous >= 0xd800 && previous <= 0xdbff) start += 1
    const candidate = value.slice(start)
    if (utf8ByteLength(candidate) <= maxBytes) {
      best = candidate
      high = middle - 1
    } else {
      low = middle + 1
    }
  }
  return best
}
