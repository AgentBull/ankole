import { isRecord, recordValue, safeJsonParse } from '@agentbull/active-support'

export type SettingValueKind = 'boolean' | 'number' | 'string' | 'object' | 'structured'
export type SettingEditorKind =
  | 'aiGatewayCompaction'
  | 'timezone'
  | 'locale'
  | 'encrypted'
  | 'optionalTokens'
  | 'duration'
  | 'limits'
  | SettingValueKind

export const SETTING_DURATIONS: Record<string, { seconds: number; min: number; max?: number }> = {
  'ai_agent.inactivity_timeout_ms': { seconds: 0.001, min: 0 },
  'agent_workers.rendered_fetch_idle_ttl_ms': { seconds: 0.001, min: 300000, max: 86400000 },
  'agent_workers.ready_timeout_seconds': { seconds: 1, min: 1, max: 31536000 },
  'brain.signal_channel_batch_idle_time': { seconds: 1, min: 1 },
  'brain.soft_delete_retention_hours': { seconds: 3600, min: Number.MIN_VALUE },
  'pod.trash_retention_days': { seconds: 86400, min: 1 },
  'pod.base.limits.statement_timeout_ms': { seconds: 0.001, min: 1 },
  'pod.applet.limits.timeout_ms': { seconds: 0.001, min: 1 },
  'authn.email.code_ttl_seconds': { seconds: 1, min: 1, max: 86400 },
  'principals.identity_providers.directory_full_sync_interval_minutes': { seconds: 60, min: 1 }
}

export const SETTING_DURATION_UNITS = [
  { id: 'seconds', seconds: 1 },
  { id: 'minutes', seconds: 60 },
  { id: 'hours', seconds: 3600 },
  { id: 'days', seconds: 86400 }
] as const

export function settingDurationParts(key: string, value: unknown) {
  const policy = SETTING_DURATIONS[key]
  if (!policy || typeof value !== 'number' || !Number.isFinite(value)) return undefined
  const seconds = value * policy.seconds
  const unit =
    SETTING_DURATION_UNITS.toReversed().find(unit => seconds > 0 && seconds % unit.seconds === 0) ??
    SETTING_DURATION_UNITS[0]
  return { amount: seconds / unit.seconds, unit: unit.id }
}

const SPECIFIC_SETTING_EDITORS = new Map<string, SettingEditorKind>([
  ['ai_gateway.compaction', 'aiGatewayCompaction'],
  ['system.timezone', 'timezone'],
  ['i18n.default_locale', 'locale'],
  ['ai_agent.max_output_tokens', 'optionalTokens'],
  ...Object.keys(SETTING_DURATIONS).map(key => [key, 'duration'] as [string, SettingEditorKind]),
  ...['pod.base.limits', 'pod.applet.limits', 'authn.email.send_limits', 'authn.email.failure_limits'].map(
    key => [key, 'limits'] as [string, SettingEditorKind]
  )
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
