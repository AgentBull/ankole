import type { TFunction } from 'i18next'

type SettingDescriptionSource = {
  key: string
  pattern_id?: string | null
  description?: string | null
}

export function settingDescription(t: TFunction, setting: SettingDescriptionSource): string | undefined {
  const configurationKey = setting.pattern_id ?? setting.key
  const translationKey = `app_configure.descriptions.${configurationKey}`
  const translated = t(translationKey)

  return translated === translationKey ? (setting.description ?? undefined) : translated
}
