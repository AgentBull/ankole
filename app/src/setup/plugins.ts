import { appConfigService } from '@/config/app-configure'
import { PluginEnabledOverridesConfig, type PluginEnabledOverrides } from '@/plugins/config'
import { loadPluginCatalog } from '@/plugins/catalog'

/**
 * Persists setup's exact plugin selection as explicit enable/disable overrides.
 *
 * Writing every known plugin makes the setup result stable when default-enabled
 * plugin lists change later: the operator's first-run choice remains explicit
 * until console changes it.
 */
export async function persistExactEnabledPluginIds(pluginIds: readonly string[]): Promise<string[]> {
  const catalog = await loadPluginCatalog()
  const selected = new Set(pluginIds)
  const known = new Set(catalog.plugins.map(plugin => plugin.metadata.id))
  const unknown = [...selected].filter(id => !known.has(id))

  if (unknown.length > 0) {
    throw Object.assign(new Error(`Unknown plugin id for setup selection: ${unknown.join(', ')}`), { status: 400 })
  }

  const overrides: PluginEnabledOverrides = {}

  for (const plugin of catalog.plugins) {
    const id = plugin.metadata.id
    if (selected.has(id)) {
      overrides[id] = true
      continue
    }

    overrides[id] = false
  }

  await appConfigService.set(PluginEnabledOverridesConfig, overrides)
  return catalog.plugins.map(plugin => plugin.metadata.id).filter(id => selected.has(id))
}
