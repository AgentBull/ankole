import type { JsonValue } from '../api/generated/types.gen'

export type SettingValueKind = 'boolean' | 'number' | 'string' | 'structured'

/** Selects the smallest control that can faithfully edit the current JSON value. */
export function settingValueKind(value: JsonValue | undefined): SettingValueKind {
  if (typeof value === 'boolean') return 'boolean'
  if (typeof value === 'number') return 'number'
  if (typeof value === 'string') return 'string'
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
