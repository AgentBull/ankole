import { createModel, signal } from '@preact/signals-react'

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
