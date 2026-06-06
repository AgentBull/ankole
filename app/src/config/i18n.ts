import { z } from 'zod'
import { defineAppConfig, registerAppConfigDefinitions } from './app-configure'
import { DEFAULT_LOCALE, SUPPORTED_LOCALES, type SupportedLocale } from './i18n-locales'

export const SupportedLocaleSchema = z.enum(SUPPORTED_LOCALES)

export const AppI18nDefaultLocaleConfig = defineAppConfig<SupportedLocale>({
  key: 'i18n.default_locale',
  encrypted: false,
  schema: SupportedLocaleSchema,
  defaultValue: DEFAULT_LOCALE,
  description: 'Application-wide default locale used by BullX Agent web surfaces'
})

registerAppConfigDefinitions([AppI18nDefaultLocaleConfig])
