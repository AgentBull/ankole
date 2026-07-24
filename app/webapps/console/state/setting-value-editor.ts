import type { AgentItem, JsonValue as JSONValue } from '../api/generated/types.gen'

export type SettingValueKind = 'boolean' | 'number' | 'string' | 'object' | 'structured'
export type SettingEditorKind = 'brainEmbedding' | 'plugins' | 'timezone' | 'locale' | 'encrypted' | SettingValueKind

const SPECIFIC_SETTING_EDITORS = new Map<string, SettingEditorKind>([
  ['brain.embedding', 'brainEmbedding'],
  ['plugins.enabled_ids', 'plugins'],
  ['system.timezone', 'timezone'],
  ['i18n.default_locale', 'locale']
])

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
