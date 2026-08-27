import type { AppConfigurationItem } from '../api/generated/types.gen'

/**
 * Declared key prefixes that one subsystem owns. A declared group replaces its member rows with one
 * row and edits every member on one page. Add a prefix here when a subsystem grows enough keys that
 * the flat list stops explaining them; nothing else in the console needs to change.
 */
const SETTING_GROUPS = [
  { id: 'brain', prefix: 'brain.' },
  { id: 'observability', prefix: 'observability.traces.' }
] as const

/** Keys whose value another console surface writes. The list sends the operator there. */
const SETTING_OWNER_ROUTES: Record<string, string> = {
  'principals.identity_providers.active': '/identity'
}

export type SettingGroupID = (typeof SETTING_GROUPS)[number]['id']

export type SettingGroup = {
  id: SettingGroupID
  items: AppConfigurationItem[]
}

export type SettingRows = {
  groups: SettingGroup[]
  managed: AppConfigurationItem[]
  singles: AppConfigurationItem[]
}

export function settingGroupID(key: string): SettingGroupID | undefined {
  return SETTING_GROUPS.find(group => key.startsWith(group.prefix))?.id
}

export function settingGroupPrefix(id: string): string | undefined {
  return SETTING_GROUPS.find(group => group.id === id)?.prefix
}

export function settingOwnerRoute(key: string): string | undefined {
  return SETTING_OWNER_ROUTES[key]
}

/**
 * Splits the list into what an operator changes and what the Installation owns.
 *
 * Ownership comes from the server's own `editable`, which carries `console_writable`. A key that
 * the release bootstrap generates or that another surface writes therefore leaves the main list
 * without a second list of key names to keep in step here.
 */
export function settingRows(items: AppConfigurationItem[]): SettingRows {
  const grouped = new Map<SettingGroupID, AppConfigurationItem[]>()
  const managed: AppConfigurationItem[] = []
  const singles: AppConfigurationItem[] = []

  for (const item of items) {
    const groupID = item.editable ? settingGroupID(item.key) : undefined

    if (!item.editable) managed.push(item)
    else if (groupID) grouped.set(groupID, [...(grouped.get(groupID) ?? []), item])
    else singles.push(item)
  }

  const groups = SETTING_GROUPS.flatMap(group => {
    const groupItems = grouped.get(group.id)
    return groupItems ? [{ id: group.id, items: groupItems }] : []
  })

  return { groups, managed, singles }
}

export function groupOverridden(group: SettingGroup): boolean {
  return group.items.some(item => item.overridden)
}
