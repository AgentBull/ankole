import { batch, computed, createModel, signal } from '@preact/signals-react'

export type TenantDraft = { slug: string; displayName: string; brainPacks: string[] }

export const TenantEditorModel = createModel(() => {
  let generation = Symbol()
  const sourceKey = signal<string>()
  const slug = signal('')
  const displayName = signal('')
  const brainPacks = signal<string[]>([])
  const initial = signal<TenantDraft>()
  const draft = computed(() => ({ slug: slug.value, displayName: displayName.value, brainPacks: brainPacks.value }))
  const dirty = computed(() => Boolean(initial.value) && JSON.stringify(initial.value) !== JSON.stringify(draft.value))
  return {
    resetSource() {
      generation = Symbol()
      sourceKey.value = undefined
    },
    sourceKey,
    slug,
    displayName,
    brainPacks,
    draft,
    dirty,
    initialize(key: string, source: TenantDraft) {
      if (sourceKey.value === key) return
      generation = Symbol()
      batch(() => {
        sourceKey.value = key
        slug.value = source.slug
        displayName.value = source.displayName
        brainPacks.value = source.brainPacks
        initial.value = source
      })
    },
    captureSave() {
      const requestedGeneration = generation
      const submitted = { slug: slug.value, displayName: displayName.value, brainPacks: brainPacks.value }
      return (accepted: TenantDraft) => {
        if (generation !== requestedGeneration) return false
        batch(() => {
          if (JSON.stringify(slug.value) === JSON.stringify(submitted.slug)) slug.value = accepted.slug
          if (JSON.stringify(displayName.value) === JSON.stringify(submitted.displayName)) {
            displayName.value = accepted.displayName
          }
          if (JSON.stringify(brainPacks.value) === JSON.stringify(submitted.brainPacks)) {
            brainPacks.value = accepted.brainPacks
          }
          initial.value = { ...accepted }
        })
        return true
      }
    }
  }
})
