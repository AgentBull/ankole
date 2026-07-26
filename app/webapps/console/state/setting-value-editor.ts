import type { AgentItem, JsonValue as JSONValue } from '../api/generated/types.gen'

export type SettingValueKind = 'boolean' | 'number' | 'string' | 'object' | 'structured'
export type SettingEditorKind =
  | 'brainDreaming'
  | 'brainEmbedding'
  | 'plugins'
  | 'timezone'
  | 'locale'
  | 'encrypted'
  | SettingValueKind

const SPECIFIC_SETTING_EDITORS = new Map<string, SettingEditorKind>([
  ['brain.dreaming', 'brainDreaming'],
  ['brain.embedding', 'brainEmbedding'],
  ['plugins.enabled_ids', 'plugins'],
  ['system.timezone', 'timezone'],
  ['i18n.default_locale', 'locale']
])

/**
 * Mirrors the bounds that `Ankole.Brain.Config` enforces, so a value out of range is reported in
 * the field instead of returning from the server as one opaque rejection. `unlimited` records how
 * each field spells "no limit": Stage B reads `0` that way, and the Stage A cold start boundary
 * reads `null` as the full retained history, which `0` does not mean.
 */
export type BrainDreamingField = {
  /** Value the field returns to when the operator clears "no limit". */
  fallback?: number
  key: string
  max: number
  min: number
  section: 'stage_a' | 'stage_b'
  unlimited?: 'null' | 'zero'
}

export const BRAIN_DREAMING_FIELDS: BrainDreamingField[] = [
  { key: 'material_limit', min: 1, max: 10_000, section: 'stage_b' },
  { key: 'token_limit', min: 0, max: 10_000_000, section: 'stage_b', unlimited: 'zero' },
  { key: 'mutation_limit', min: 0, max: 100_000, section: 'stage_b', unlimited: 'zero' },
  { key: 'curation_silence_minutes', min: 0, max: 1_440, section: 'stage_b' },
  { key: 'curation_backlog_rows', min: 1, max: 10_000, section: 'stage_b' },
  { key: 'episode_silence_minutes', min: 0, max: 1_440, section: 'stage_a' },
  { key: 'episode_backlog_rows', min: 1, max: 10_000, section: 'stage_a' },
  { key: 'episode_window_max_rows', min: 1, max: 500, section: 'stage_a' },
  { key: 'episode_window_max_tokens', min: 500, max: 200_000, section: 'stage_a' },
  { key: 'episode_tail_guard_rows', min: 0, max: 200, section: 'stage_a' },
  { key: 'episode_tail_guard_minutes', min: 0, max: 1_440, section: 'stage_a' },
  {
    key: 'episode_cold_start_lookback_days',
    min: 0,
    max: 36_500,
    section: 'stage_a',
    unlimited: 'null',
    fallback: 5
  }
]

/** `default` keeps `enabled` absent, which every Agent reads as enabled. */
export type BrainDreamingEnabled = 'default' | 'off' | 'on'

export type BrainDreamingDraft = {
  enabled: BrainDreamingEnabled
  numbers: Record<string, string>
}

export type BrainEmbeddingDraft = {
  dimensions: string
  enabled: boolean
  modelAgentUID: string
}

export type BrainEmbeddingAgentOption = {
  displayName?: string | null
  model: string
  providerID: string
  uid: string
}

export type BrainEmbeddingValidationError = 'dimensions' | 'invalid' | 'model_agent'

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

export function brainEmbeddingDraft(text: string): BrainEmbeddingDraft {
  try {
    const value: unknown = JSON.parse(text)
    const object = record(value)
    const dimensions = object?.dimensions

    return {
      enabled: object?.enabled === true,
      modelAgentUID: typeof object?.model_agent_uid === 'string' ? object.model_agent_uid : '',
      dimensions: typeof dimensions === 'number' && Number.isInteger(dimensions) ? String(dimensions) : ''
    }
  } catch {
    return { enabled: false, modelAgentUID: '', dimensions: '' }
  }
}

export function serializeBrainEmbeddingDraft(draft: BrainEmbeddingDraft): string {
  const dimensions = draft.dimensions.trim()

  return JSON.stringify(
    {
      enabled: draft.enabled,
      model_agent_uid: draft.modelAgentUID.trim() || null,
      dimensions: dimensions ? Number(dimensions) : null
    },
    null,
    2
  )
}

export function brainEmbeddingValidationError(value: JSONValue): BrainEmbeddingValidationError | undefined {
  const object = record(value)
  if (!object || typeof object.enabled !== 'boolean') return 'invalid'
  if (
    object.dimensions !== null &&
    object.dimensions !== undefined &&
    (typeof object.dimensions !== 'number' ||
      !Number.isInteger(object.dimensions) ||
      object.dimensions < 1 ||
      object.dimensions > 4_096)
  ) {
    return 'dimensions'
  }
  if (!object.enabled) return undefined
  if (typeof object.model_agent_uid !== 'string' || !object.model_agent_uid.trim()) return 'model_agent'
  if (typeof object.dimensions !== 'number') return 'dimensions'
  return undefined
}

export function brainDreamingDraft(text: string): BrainDreamingDraft {
  const object = (() => {
    try {
      return record(JSON.parse(text))
    } catch {
      return undefined
    }
  })()

  const numbers: Record<string, string> = {}

  for (const field of BRAIN_DREAMING_FIELDS) {
    const value = object?.[field.key]
    numbers[field.key] = typeof value === 'number' && Number.isInteger(value) ? String(value) : ''
  }

  return { enabled: brainDreamingEnabled(object?.enabled), numbers }
}

export function serializeBrainDreamingDraft(draft: BrainDreamingDraft): string {
  const value: Record<string, unknown> = {
    enabled: draft.enabled === 'default' ? null : draft.enabled === 'on'
  }

  for (const field of BRAIN_DREAMING_FIELDS) {
    const text = (draft.numbers[field.key] ?? '').trim()
    value[field.key] = text === '' ? null : Number(text)
  }

  return JSON.stringify(value, null, 2)
}

/** Reports the offending field key, or `invalid` when the value is not a dreaming object at all. */
export function brainDreamingValidationError(value: JSONValue): string | undefined {
  const object = record(value)
  if (!object) return 'invalid'
  if (object.enabled !== null && typeof object.enabled !== 'boolean') return 'invalid'

  return BRAIN_DREAMING_FIELDS.find(field => {
    const current = object[field.key]
    if (current === null || current === undefined) return field.unlimited !== 'null'
    return typeof current !== 'number' || !Number.isInteger(current) || current < field.min || current > field.max
  })?.key
}

function brainDreamingEnabled(value: unknown): BrainDreamingEnabled {
  if (value === true) return 'on'
  if (value === false) return 'off'
  return 'default'
}

export function brainEmbeddingAgentOptions(
  agents: Array<Pick<AgentItem, 'display_name' | 'options' | 'status' | 'uid'>>
): BrainEmbeddingAgentOption[] {
  return agents
    .flatMap(agent => {
      if (agent.status !== 'active') return []

      const aiAgent = record(agent.options.ai_agent)
      const models = record(aiAgent?.models)
      const embedding = record(models?.embedding)
      const model = embedding?.model
      const providerID = embedding?.provider_id

      if (typeof model !== 'string' || !model.trim() || typeof providerID !== 'string' || !providerID.trim()) return []

      return [
        {
          uid: agent.uid,
          displayName: agent.display_name,
          model,
          providerID
        }
      ]
    })
    .sort((left, right) => left.uid.localeCompare(right.uid))
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
