import type {
  AgentLibrarySkillCapabilityItem,
  AgentPluginCapabilityItem,
  ControlPlanePluginItem,
  JsonValue as JSONValue
} from '../api/generated/types.gen'
import { matchesResourceSearch } from './resource-search'

export const GLOBAL_LIBRARY_SCOPE = '__global__'

export type AgentLibraryTab = 'agent-plugins' | 'skills' | 'control-plane-plugins'
export type AgentLibraryOverrideValue = 'inherit' | 'enabled' | 'disabled'

export function availableAgentLibraryTabs(scope: string): AgentLibraryTab[] {
  return scope === GLOBAL_LIBRARY_SCOPE
    ? ['agent-plugins', 'skills', 'control-plane-plugins']
    : ['agent-plugins', 'skills']
}

export function agentLibraryOverrideValue(value: boolean | null): AgentLibraryOverrideValue {
  if (value === null) return 'inherit'
  return value ? 'enabled' : 'disabled'
}

export function parseAgentLibraryOverrideValue(value: string): boolean | null {
  switch (value) {
    case 'inherit':
      return null
    case 'enabled':
      return true
    case 'disabled':
      return false
    default:
      throw new Error(`invalid Agent Library override value: ${value}`)
  }
}

export function filterAgentPlugins(items: AgentPluginCapabilityItem[], query: string) {
  return items.filter(item =>
    matchesResourceSearch(
      query,
      item.id,
      item.description,
      item.version,
      ...item.skills.flatMap(skill => [skill.name, skill.description])
    )
  )
}

export function filterSkills(items: AgentLibrarySkillCapabilityItem[], query: string) {
  return items.filter(item => matchesResourceSearch(query, item.id, item.name, item.description, item.source_kind))
}

export function filterControlPlanePlugins(items: ControlPlanePluginItem[], query: string, locale = 'en-US') {
  return items.filter(item =>
    matchesResourceSearch(
      query,
      item.id,
      localizedJSONText(item.display_name, locale),
      localizedJSONText(item.description, locale)
    )
  )
}

export function localizedJSONText(value: JSONValue, locale = 'en-US'): string {
  if (typeof value === 'string') return value
  if (!value || Array.isArray(value) || typeof value !== 'object') return value == null ? '' : String(value)
  const localized = value as Record<string, JSONValue>
  const candidate = localized[locale] ?? localized[locale.split('-')[0]] ?? localized['en-US'] ?? localized.en
  if (typeof candidate === 'string') return candidate
  return JSON.stringify(value)
}

export function humanizeAgentPluginID(id: string): string {
  return id
    .split('-')
    .map(part => part.charAt(0).toUpperCase() + part.slice(1))
    .join(' ')
}

export function agentLibraryScopeQuery(path: string, scope: string): string {
  return scope === GLOBAL_LIBRARY_SCOPE ? path : `${path}?scope=${encodeURIComponent(scope)}`
}
