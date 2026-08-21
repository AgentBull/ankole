import { createModel, signal } from '@preact/signals-react'

export function filterSelectedPluginItems<T extends { pluginID: string }>(
  items: readonly T[],
  selectedPluginIDs: ReadonlySet<string>
): T[] {
  return items.filter(item => selectedPluginIDs.has(item.pluginID))
}

/**
 * Identity adapters the setup identity step offers: the built-in local
 * adapter always comes first, and plugin adapters follow the plugin
 * selection. The local adapter belongs to no selectable plugin, so the
 * plugin filter alone would drop it.
 */
export function visibleIdentityAdapters<T extends { adapterID: string; pluginID: string }>(
  adapters: readonly T[],
  selectedPluginIDs: ReadonlySet<string>
): T[] {
  const local = adapters.filter(adapter => adapter.adapterID === 'local')
  const pluginAdapters = adapters.filter(adapter => adapter.adapterID !== 'local')

  return [...local, ...filterSelectedPluginItems(pluginAdapters, selectedPluginIDs)]
}

export const PluginsStepModel = createModel(() => {
  const sourceKey = signal<string>()
  const selectedPluginIDs = signal<ReadonlySet<string>>(new Set())

  return {
    sourceKey,
    selectedPluginIDs,
    initialize(nextSourceKey: string, enabledPluginIDs: string[]) {
      if (sourceKey.value === nextSourceKey) return
      sourceKey.value = nextSourceKey
      selectedPluginIDs.value = new Set(enabledPluginIDs)
    },
    setPluginSelected(pluginID: string, selected: boolean) {
      const next = new Set(selectedPluginIDs.value)
      selected ? next.add(pluginID) : next.delete(pluginID)
      selectedPluginIDs.value = next
    },
    submission() {
      return { pluginIDs: [...selectedPluginIDs.value] }
    }
  }
})
