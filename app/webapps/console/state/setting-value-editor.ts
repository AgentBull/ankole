import type { JsonValue as JSONValue } from '../api/generated/types.gen'

export type SettingValueKind = 'boolean' | 'number' | 'string' | 'object' | 'structured'
export type SettingEditorKind =
  | 'aiGatewayCompaction'
  | 'plugins'
  | 'timezone'
  | 'locale'
  | 'encrypted'
  | SettingValueKind

const SPECIFIC_SETTING_EDITORS = new Map<string, SettingEditorKind>([
  ['ai_gateway.compaction', 'aiGatewayCompaction'],
  ['plugins.enabled_ids', 'plugins'],
  ['system.timezone', 'timezone'],
  ['i18n.default_locale', 'locale']
])

/**
 * Mirrors the bounds that `Ankole.AIGateway.Compaction` enforces, so a value out
 * of range is reported in the field instead of returning as one opaque server
 * rejection. `threshold` is a ratio of the model input context, so it is the one
 * field that is not an integer.
 */
export type CompactionField = {
  key: string
  max: number
  min: number
  step?: number
}

export const AI_GATEWAY_COMPACTION_FIELDS: CompactionField[] = [
  { key: 'threshold', min: 0.01, max: 1, step: 0.01 },
  { key: 'max_threshold_tokens', min: 1, max: 10_000_000 },
  { key: 'tail_rows', min: 0, max: 1_000 },
  { key: 'user_message_budget_tokens', min: 1, max: 1_000_000 }
]

export type AIGatewayCompactionDraft = {
  numbers: Record<string, string>
  upstream: boolean
}

export function aiGatewayCompactionDraft(text: string): AIGatewayCompactionDraft {
  const object = (() => {
    try {
      return record(JSON.parse(text))
    } catch {
      return undefined
    }
  })()

  const numbers: Record<string, string> = {}

  for (const field of AI_GATEWAY_COMPACTION_FIELDS) {
    const value = object?.[field.key]
    numbers[field.key] = typeof value === 'number' ? String(value) : ''
  }

  return { numbers, upstream: object?.upstream === true }
}

export function serializeAIGatewayCompactionDraft(draft: AIGatewayCompactionDraft): string {
  const value: Record<string, unknown> = { upstream: draft.upstream }

  for (const field of AI_GATEWAY_COMPACTION_FIELDS) {
    const text = (draft.numbers[field.key] ?? '').trim()
    if (text !== '') value[field.key] = Number(text)
  }

  return JSON.stringify(value, null, 2)
}

/** Resolves an exact-key editor before falling back to the value-shape controls. */
export function settingEditorKind(key: string, encrypted: boolean, value: JSONValue | undefined): SettingEditorKind {
  const specific = SPECIFIC_SETTING_EDITORS.get(key)
  if (specific) return specific
  if (encrypted) return 'encrypted'
  return settingValueKind(value)
}

/** Selects the smallest control that can faithfully edit the current JSON value. */
export function settingValueKind(value: JSONValue | undefined): SettingValueKind {
  if (typeof value === 'boolean') return 'boolean'
  if (typeof value === 'number') return 'number'
  if (typeof value === 'string') return 'string'
  if (typeof value === 'object' && value !== null && !Array.isArray(value)) return 'object'
  return 'structured'
}

export function settingStringDraft(text: string): string {
  try {
    const value: unknown = JSON.parse(text)
    return typeof value === 'string' ? value : ''
  } catch {
    return ''
  }
}

export function pluginIDsFromDraft(text: string): string[] {
  try {
    const value: unknown = JSON.parse(text)
    if (!Array.isArray(value) || value.some(item => typeof item !== 'string')) return []
    return [...new Set(value)].sort()
  } catch {
    return []
  }
}

export function togglePluginID(pluginIDs: string[], pluginID: string, selected: boolean): string[] {
  const next = new Set(pluginIDs)
  selected ? next.add(pluginID) : next.delete(pluginID)
  return [...next].sort()
}

export function unknownPluginIDs(pluginIDs: string[], discoveredIDs: string[]): string[] {
  const discovered = new Set(discoveredIDs)
  return pluginIDs.filter(id => !discovered.has(id)).sort()
}

export function pluginRestartRequired(active: boolean, configuredForNextStart: boolean): boolean {
  return active !== configuredForNextStart
}

function record(value: unknown): Record<string, unknown> | undefined {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : undefined
}
