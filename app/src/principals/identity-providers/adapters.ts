import type { BullXIdentityProviderAdapterFactory, BullXIdentityProviderAdapterSetup } from '@agentbull/bullx-sdk/plugins'
import { loadPluginCatalog } from '@/plugins/catalog'

export interface IdentityProviderAdapterDescriptor {
  id: string
  pluginId: string
  setup?: BullXIdentityProviderAdapterSetup
}

export async function listEnabledIdentityProviderAdapters(): Promise<IdentityProviderAdapterDescriptor[]> {
  const catalog = await loadPluginCatalog()
  const enabled = new Set(catalog.enabledPluginIds)
  const adapters: IdentityProviderAdapterDescriptor[] = []

  for (const plugin of catalog.plugins) {
    if (!enabled.has(plugin.metadata.id)) continue

    for (const adapter of plugin.identityProviderAdapters ?? []) {
      adapters.push({
        id: adapter.id,
        pluginId: plugin.metadata.id,
        setup: adapter.setup
      })
    }
  }

  return adapters
}

export async function getEnabledIdentityProviderAdapter(adapterId: string): Promise<BullXIdentityProviderAdapterFactory> {
  const catalog = await loadPluginCatalog()
  const enabled = new Set(catalog.enabledPluginIds)

  for (const plugin of catalog.plugins) {
    if (!enabled.has(plugin.metadata.id)) continue

    const adapter = (plugin.identityProviderAdapters ?? []).find(candidate => candidate.id === adapterId)
    if (adapter) return adapter
  }

  throw new Error(`Identity provider adapter is not enabled: ${adapterId}`)
}
