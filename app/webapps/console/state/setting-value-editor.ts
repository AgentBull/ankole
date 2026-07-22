import type { JsonValue as JSONValue } from '../api/generated/types.gen'

export type SettingValueKind = 'boolean' | 'number' | 'string' | 'object' | 'structured'
export type SettingEditorKind = 'plugins' | 'timezone' | 'locale' | 'encrypted' | SettingValueKind

const SPECIFIC_SETTING_EDITORS = new Map<string, SettingEditorKind>([
  ['plugins.enabled_ids', 'plugins'],
  ['system.timezone', 'timezone'],
  ['i18n.default_locale', 'locale']
])

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
