import type { TFunction } from 'i18next'

type GroupText = { built_in: boolean; name: string; display_name: string; description?: string | null }

/**
 * Built-in groups are seeded with English text that the operator may later
 * edit. The catalog translates a built-in only while its stored text still
 * equals the seed (the en-US catalog entry is that seed), so a rename shows
 * as typed. Callers that search or render the group use the same value.
 */
export function principalGroupDisplayName(t: TFunction, group: GroupText): string {
  return catalogOverride(t, `console.principal_groups.builtin_${group.name}_name`, group)(group.display_name)
}

export function principalGroupDescription(t: TFunction, group: GroupText): string | undefined {
  return group.description == null
    ? undefined
    : catalogOverride(t, `console.principal_groups.builtin_${group.name}_description`, group)(group.description)
}

function catalogOverride(t: TFunction, key: string, group: GroupText): (stored: string) => string {
  return stored => {
    if (!group.built_in) return stored
    const seed = t(key, { defaultValue: '', lng: 'en-US' })
    if (!seed || seed !== stored) return stored
    return t(key, { defaultValue: stored })
  }
}
