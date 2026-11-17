import type { TFunction } from 'i18next'
import type { AppConfigurationItem } from '../api/configuration-types'

/**
 * Declared key prefixes that one subsystem owns. Each group selects its typed editor.
 */
const SETTING_GROUPS = [
  { id: 'brain', prefix: 'brain.' },
  { id: 'observability', prefix: 'observability.traces.' },
  { id: 'smtp', prefix: 'authn.email.mail' },
  { id: 'otp', prefix: 'authn.email.' }
] as const

/** Keys whose value another console surface writes. The list sends the operator there. */
const SETTING_OWNER_ROUTES: Record<string, string> = {
  'principals.identity_providers.active': '/identity',
  'plugins.enabled_ids': '/agent-library?scope=__global__&tab=control-plane-plugins',
  'ai_agent.library.agent_plugin_defaults': '/agent-library?scope=__global__&tab=agent-plugins'
}

export interface SettingGroupDefinition {
  id: string
  prefix: string
  required?: (drafts: Record<string, string>) => boolean
  hint?: string
}

export interface SettingOwnerDefinition {
  key: string
  route: string
  label: string
}

export type SettingGroupID = string

export type SettingGroup = {
  id: SettingGroupID
  items: AppConfigurationItem[]
}

export type SettingRows = {
  groups: SettingGroup[]
  managed: AppConfigurationItem[]
  singles: AppConfigurationItem[]
}

export function settingGroupID(
  key: string,
  groups: readonly SettingGroupDefinition[] = []
): SettingGroupID | undefined {
  return [...SETTING_GROUPS, ...groups].find(group => key.startsWith(group.prefix))?.id
}

export function settingGroup(
  id: string,
  groups: readonly SettingGroupDefinition[] = []
): SettingGroupDefinition | undefined {
  return [...SETTING_GROUPS, ...groups].find(group => group.id === id)
}

export function settingOwnerRoute(
  key: string,
  scope?: 'global' | 'tenant',
  owners: readonly SettingOwnerDefinition[] = []
): string | undefined {
  const extension = owners.find(owner => owner.key === key)
  if (extension) return extension.route
  const base =
    SETTING_OWNER_ROUTES[key] ??
    (key.startsWith('ai_gateway.model_profiles.') || key.startsWith('ai_gateway.provider_hosted.')
      ? '/model-profiles'
      : key.startsWith('principals.identity_providers.') &&
          key !== 'principals.identity_providers.directory_full_sync_interval_minutes'
        ? '/identity'
        : key.startsWith('signals.') && key !== 'signals.show_dead_letter_error_details'
          ? '/signals'
          : undefined)
  if (!base || !scope) return base
  if (key.startsWith('ai_agent.library.')) return `${base}&defaults_scope=${scope}`
  if (key.startsWith('ai_gateway.')) return `${base}?defaults_scope=${scope}`
  return base
}

export function settingDescription(
  t: TFunction,
  setting: Pick<AppConfigurationItem, 'key' | 'pattern_id' | 'description'>
): string | undefined {
  const translationKey = `app_configure.descriptions.${setting.pattern_id ?? setting.key}`
  const translated = t(translationKey)
  return translated === translationKey ? (setting.description ?? undefined) : translated
}

/**
 * Groups daily editing tasks, retaining read-only members as task dependencies.
 * Other installation-owned keys remain available in the registry view.
 */
export function settingRows(
  items: AppConfigurationItem[],
  extensions: readonly SettingGroupDefinition[] = []
): SettingRows {
  const grouped = new Map<SettingGroupID, AppConfigurationItem[]>()
  const managed: AppConfigurationItem[] = []
  const singles: AppConfigurationItem[] = []

  for (const item of items) {
    const groupID = settingGroupID(item.key, extensions)

    if (groupID) grouped.set(groupID, [...(grouped.get(groupID) ?? []), item])
    else if (!item.editable) managed.push(item)
    else singles.push(item)
  }

  const groups = [...SETTING_GROUPS, ...extensions].flatMap(group => {
    const groupItems = grouped.get(group.id)
    return groupItems ? [{ id: group.id, items: groupItems }] : []
  })

  return { groups, managed, singles }
}
