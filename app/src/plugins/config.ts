import { z } from 'zod'
import { defineAppConfig, registerAppConfigDefinitions } from '@/config/app-configure'

export type PluginEnabledOverrides = Record<string, boolean>

export const PluginEnabledOverridesConfig = defineAppConfig({
  key: 'plugins.enabled_overrides',
  encrypted: false,
  schema: z.record(z.string(), z.boolean()),
  defaultValue: {},
  description: 'Per-plugin enablement overrides applied at BullX Agent process startup'
})

registerAppConfigDefinitions([PluginEnabledOverridesConfig])
