import { batch, computed, createModel, signal } from '@preact/signals-react'

export type TenantDraft = { slug: string; displayName: string; brainPacks: string[] }

export const TenantEditorModel = createModel(() => {
  const sourceKey = signal<string>()
  const slug = signal('')
  const displayName = signal('')
  const brainPacks = signal<string[]>([])
  const initial = signal<TenantDraft>()
  const draft = computed(() => ({ slug: slug.value, displayName: displayName.value, brainPacks: brainPacks.value }))
  const dirty = computed(() => Boolean(initial.value) && JSON.stringify(initial.value) !== JSON.stringify(draft.value))
  return {
    sourceKey,
    slug,
    displayName,
    brainPacks,
    draft,
    dirty,
    initialize(key: string, source: TenantDraft) {
      if (sourceKey.value === key) return
      batch(() => {
        sourceKey.value = key
        slug.value = source.slug
        displayName.value = source.displayName
        brainPacks.value = source.brainPacks
        initial.value = source
      })
    },
    markSaved() {
      initial.value = draft.value
    }
  }
})
