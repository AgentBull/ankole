import type { BullXPlugin } from '@agentbull/bullx-sdk/plugins'
import { appConfigService } from '@/config/app-configure'
import { PluginEnabledOverridesConfig, type PluginEnabledOverrides } from './config'
import { discoverLocalPluginsDetailed } from './discovery'
import {
  buildPluginRegistry,
  effectiveDefaultEnabledPluginIds,
  resolveEnabledPluginIds,
  type PluginRegistry
} from './runtime'

export interface PluginCatalog {
  plugins: readonly BullXPlugin[]
  registry: PluginRegistry
  enabledPluginIds: string[]
  overrides: PluginEnabledOverrides
}

/**
 * Loads the operator-facing plugin catalog with effective enablement state.
 *
 * This intentionally reuses runtime registry validation so setup/console show
 * the same duplicate-id and adapter-collision failures that process startup
 * would hit.
 */
export async function loadPluginCatalog(): Promise<PluginCatalog> {
  const { plugins, autoEnabledPluginIds } = await discoverLocalPluginsDetailed()
  const registry = buildPluginRegistry(plugins)
  const overrides = (await appConfigService.get(PluginEnabledOverridesConfig)) ?? {}
  const enabledPluginIds = resolveEnabledPluginIds({
    defaultEnabledPluginIds: effectiveDefaultEnabledPluginIds(autoEnabledPluginIds),
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
