import type {
  BullXIdentityProviderAdapterFactory,
  BullXIdentityProviderAdapterSetup,
  BullXPlugin,
  BullXPluginJsonValue
} from '@agentbull/bullx-sdk/plugins'
import { appConfigService } from '@/config/app-configure'
import {
  buildPluginRegistry,
  defaultEnabledPluginIds,
  resolveEnabledPluginIds,
  type PluginRegistry
} from '@/plugins/runtime'
import { PluginEnabledOverridesConfig, type PluginEnabledOverrides } from '@/plugins/config'
import { discoverLocalPlugins } from '@/plugins/discovery'

export interface SetupPluginCatalog {
  plugins: readonly BullXPlugin[]
  registry: PluginRegistry
  enabledPluginIds: string[]
  overrides: PluginEnabledOverrides
}

export interface SetupIdentityProviderAdapterDescriptor {
  id: string
  pluginId: string
  setup?: BullXIdentityProviderAdapterSetup
}

export async function loadSetupPluginCatalog(): Promise<SetupPluginCatalog> {
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

export async function persistExactEnabledPluginIds(pluginIds: readonly string[]): Promise<string[]> {
  const catalog = await loadSetupPluginCatalog()
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

export async function listSetupIdentityProviderAdapters(): Promise<SetupIdentityProviderAdapterDescriptor[]> {
  const catalog = await loadSetupPluginCatalog()
  const enabled = new Set(catalog.enabledPluginIds)
  const adapters: SetupIdentityProviderAdapterDescriptor[] = []

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

export async function getSetupIdentityProviderAdapter(adapterId: string): Promise<BullXIdentityProviderAdapterFactory> {
  const catalog = await loadSetupPluginCatalog()
  const enabled = new Set(catalog.enabledPluginIds)

  for (const plugin of catalog.plugins) {
    if (!enabled.has(plugin.metadata.id)) continue

    const adapter = (plugin.identityProviderAdapters ?? []).find(candidate => candidate.id === adapterId)
    if (adapter) return adapter
  }

  throw new Error(`Identity provider adapter is not enabled for setup: ${adapterId}`)
}

export function clonePluginJsonValue<TValue extends BullXPluginJsonValue | undefined>(value: TValue): TValue {
  if (value === undefined) return value

  return JSON.parse(JSON.stringify(value)) as TValue
}
