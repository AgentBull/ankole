import type { BullXPlugin } from '@agentbull/bullx-sdk/plugins'
import { appConfigService } from '@/config/app-configure'
import { PluginEnabledOverridesConfig, type PluginEnabledOverrides } from './config'
import { discoverLocalPlugins } from './discovery'
import {
  buildPluginRegistry,
  defaultEnabledPluginIds,
  resolveEnabledPluginIds,
  type PluginRegistry
} from './runtime'

export interface PluginCatalog {
  plugins: readonly BullXPlugin[]
  registry: PluginRegistry
  enabledPluginIds: string[]
  overrides: PluginEnabledOverrides
}

export async function loadPluginCatalog(): Promise<PluginCatalog> {
  const plugins = await discoverLocalPlugins()
  const registry = buildPluginRegistry(plugins)
  const overrides = (await appConfigService.get(PluginEnabledOverridesConfig)) ?? {}
  const enabledPluginIds = resolveEnabledPluginIds({
    defaultEnabledPluginIds,
    overrides,
    registry
  })

  return {
    plugins,
    registry,
    enabledPluginIds,
    overrides
  }
}
