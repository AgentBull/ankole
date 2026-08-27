import { createModel, signal } from '@preact/signals-react'

export type BrainPack = {
  name: string
  description?: string | null
  version?: string | null
  required: boolean
}

/**
 * Industry pack selection for the setup wizard. The base pack is always
 * installed, so the model tracks only the optional industry packs; the server
 * rejects unknown names and strips the base pack on write.
 */
export const BrainPacksStepModel = createModel(() => {
  const sourceKey = signal<string>()
  const selectedPacks = signal<ReadonlySet<string>>(new Set())

  return {
    sourceKey,
    selectedPacks,
    initialize(nextSourceKey: string, selected: string[]) {
      if (sourceKey.value === nextSourceKey) return
      sourceKey.value = nextSourceKey
      selectedPacks.value = new Set(selected)
    },
    setPackSelected(name: string, selected: boolean) {
      const next = new Set(selectedPacks.value)
      selected ? next.add(name) : next.delete(name)
      selectedPacks.value = next
    },
    submission() {
      return { packs: [...selectedPacks.value] }
    }
  }
})
