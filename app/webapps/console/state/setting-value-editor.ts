import { isRecord, recordValue, safeJsonParse } from '@agentbull/active-support'

export type SettingValueKind = 'boolean' | 'number' | 'string' | 'object' | 'structured'
export type SettingEditorKind = 'aiGatewayCompaction' | 'timezone' | 'locale' | 'encrypted' | SettingValueKind

const SPECIFIC_SETTING_EDITORS = new Map<string, SettingEditorKind>([
  ['ai_gateway.compaction', 'aiGatewayCompaction'],
  ['system.timezone', 'timezone'],
  ['i18n.default_locale', 'locale']
])

/**
 * Field controls follow `Ankole.AIGateway.CompactionPolicy`. Integer maxima
 * prevent JSON number precision loss in the Console.
 */
export type CompactionField = {
  key: string
  max: number
  min: number
  step?: number | 'any'
}

export const AI_GATEWAY_COMPACTION_FIELDS: CompactionField[] = [
  { key: 'threshold', min: Number.MIN_VALUE, max: 1, step: 'any' },
  { key: 'max_threshold_tokens', min: 1, max: Number.MAX_SAFE_INTEGER },
  { key: 'tail_rows', min: 0, max: Number.MAX_SAFE_INTEGER },
  { key: 'user_message_budget_tokens', min: 1, max: Number.MAX_SAFE_INTEGER }
]

export type AIGatewayCompactionDraft = {
  numbers: Record<string, string>
  upstream: boolean
}

export function aiGatewayCompactionDraft(text: string): AIGatewayCompactionDraft {
  const object = recordValue(safeJsonParse(text).unwrapOr(undefined))

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
export function settingEditorKind(key: string, encrypted: boolean, value: unknown): SettingEditorKind {
  const specific = SPECIFIC_SETTING_EDITORS.get(key)
  if (specific) return specific
  if (encrypted) return 'encrypted'
  return settingValueKind(value)
}

/** Selects the smallest control that can faithfully edit the current JSON value. */
export function settingValueKind(value: unknown): SettingValueKind {
  if (typeof value === 'boolean') return 'boolean'
  if (typeof value === 'number') return 'number'
  if (typeof value === 'string') return 'string'
  if (isRecord(value)) return 'object'
  return 'structured'
}

export function settingStringDraft(text: string): string {
  const value = safeJsonParse(text).unwrapOr(undefined)
  return typeof value === 'string' ? value : ''
}
