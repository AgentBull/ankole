import type { GetGlobalLibraryCapabilitiesResponse } from '../api/v2/generated/types.gen'
import type { ListControlPlanePluginsResponse } from '../api/v2-site/generated/types.gen'
import { localizedText } from '../../common/config-fields'
import { matchesResourceSearch } from './resource-search'

export type AgentLibraryCapabilitiesResponse = GetGlobalLibraryCapabilitiesResponse
export type AgentLibrarySkillCapabilityItem = AgentLibraryCapabilitiesResponse['skills'][number]
export type AgentPluginCapabilityItem = AgentLibraryCapabilitiesResponse['agent_plugins'][number]
export type ControlPlanePluginItem = ListControlPlanePluginsResponse['control_plane_plugins'][number]

export const GLOBAL_LIBRARY_SCOPE = '__global__'

export type AgentLibraryTab = 'agent-plugins' | 'skills' | 'control-plane-plugins'
export type AgentLibraryOverrideValue = 'inherit' | 'enabled' | 'disabled'

export function availableAgentLibraryTabs(scope: string): AgentLibraryTab[] {
  return scope === GLOBAL_LIBRARY_SCOPE
    ? ['agent-plugins', 'skills', 'control-plane-plugins']
    : ['agent-plugins', 'skills']
}

export function agentLibraryOverrideValue(value: boolean | null | undefined): AgentLibraryOverrideValue {
  if (value == null) return 'inherit'
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
      localizedText(item.display_name, locale),
      localizedText(item.description, locale)
    )
  )
}

export function humanizeAgentPluginID(id: string): string {
  return id
    .split('-')
    .map(part => part.charAt(0).toUpperCase() + part.slice(1))
    .join(' ')
}

export function agentLibraryScopeQuery(path: string, scope: string, current?: URLSearchParams): string {
  const params = new URLSearchParams(current)
  if (scope === GLOBAL_LIBRARY_SCOPE) params.delete('scope')
  else params.set('scope', scope)
  const query = params.toString()
  return query ? `${path}?${query}` : path
}
