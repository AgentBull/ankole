import { isRecord } from '@agentbull/active-support'
import type { JsonValue as JSONValue } from '../api/generated/types.gen'

export const OBSERVABILITY_TRACE_KEYS = {
  enabled: 'observability.traces.enabled',
  endpoint: 'observability.traces.otlp_endpoint',
  headers: 'observability.traces.otlp_headers',
  provider: 'observability.traces.provider'
} as const

export const OBSERVABILITY_TRACE_PROVIDERS = ['langfuse', 'langsmith', 'opentelemetry'] as const

export type ObservabilityTraceProvider = (typeof OBSERVABILITY_TRACE_PROVIDERS)[number]

export type ObservabilityHeaderRow = {
  id: string
  name: string
  value: string
}

export type ObservabilityTraceDraft = {
  enabled: boolean
  endpoint: string
  provider: string
}

export type ObservabilityTraceValidationError =
  | 'endpoint_invalid'
  | 'endpoint_required'
  | 'endpoint_signal_path'
  | 'provider_required'

export type ObservabilityHeadersValidationError = 'header_duplicate' | 'header_name_required'

export function observabilityTraceDraft(drafts: Record<string, string>): ObservabilityTraceDraft {
  return {
    enabled: drafts[OBSERVABILITY_TRACE_KEYS.enabled] === 'true',
    endpoint: stringDraft(drafts[OBSERVABILITY_TRACE_KEYS.endpoint]),
    provider: stringDraft(drafts[OBSERVABILITY_TRACE_KEYS.provider])
  }
}

export function observabilityTraceValidationError(
  draft: ObservabilityTraceDraft
): ObservabilityTraceValidationError | undefined {
  if (draft.enabled && !OBSERVABILITY_TRACE_PROVIDERS.includes(draft.provider as ObservabilityTraceProvider)) {
    return 'provider_required'
  }
  if (!draft.endpoint.trim()) return draft.enabled ? 'endpoint_required' : undefined

  let endpoint: URL
  try {
    endpoint = new URL(draft.endpoint)
  } catch {
    return 'endpoint_invalid'
  }

  if (
    !['http:', 'https:'].includes(endpoint.protocol) ||
    !endpoint.hostname ||
    endpoint.username ||
    endpoint.password ||
    endpoint.search ||
    endpoint.hash
  ) {
    return 'endpoint_invalid'
  }

  if (endpoint.pathname.toLowerCase().replace(/\/$/, '').endsWith('/v1/traces')) {
    return 'endpoint_signal_path'
  }

  return undefined
}

export function observabilityHeaderRows(value: JSONValue): ObservabilityHeaderRow[] | undefined {
  if (!isRecord(value)) return undefined

  const entries = Object.entries(value)
  if (entries.some(([, headerValue]) => typeof headerValue !== 'string')) return undefined

  return entries.map(([name, headerValue], index) => ({
    id: `stored-${index}`,
    name,
    value: headerValue as string
  }))
}

export function observabilityHeadersValidationError(
  rows: ObservabilityHeaderRow[]
): ObservabilityHeadersValidationError | undefined {
  const names = rows.map(row => row.name.trim())
  if (names.some(name => !name)) return 'header_name_required'
  if (new Set(names.map(name => name.toLowerCase())).size !== names.length) return 'header_duplicate'
  return undefined
}

export function observabilityHeadersValue(rows: ObservabilityHeaderRow[]): Record<string, string> {
  return Object.fromEntries(rows.map(row => [row.name.trim(), row.value]))
}

export function sameObservabilityHeaderRows(
  left: ObservabilityHeaderRow[] | undefined,
  right: ObservabilityHeaderRow[] | undefined
): boolean {
  if (!left || !right) return left === right
  if (left.length !== right.length) return false
  return left.every((row, index) => row.name === right[index]?.name && row.value === right[index]?.value)
}

function stringDraft(text: string | undefined): string {
  if (!text) return ''
  try {
    const value: unknown = JSON.parse(text)
    return typeof value === 'string' ? value : ''
  } catch {
    return ''
  }
}
