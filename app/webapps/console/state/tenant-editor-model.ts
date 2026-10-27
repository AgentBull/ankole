import { equal } from '@agentbull/active-support'
import { batch, computed, createModel, signal } from '@preact/signals-react'
import { deriveSlugWithTransliteration, preloadTransliteration, slugFromDisplayName } from './agent-editor-model'

export type TenantDraft = { slug: string; displayName: string; brainPacks: string[] }

export const TenantEditorModel = createModel(() => {
  let generation = Symbol()
  let slugManuallyEdited = false
  const sourceKey = signal<string>()
  const slug = signal('')
  const displayName = signal('')
  const brainPacks = signal<string[]>([])
  const initial = signal<TenantDraft>()
  const draft = computed(() => ({ slug: slug.value, displayName: displayName.value, brainPacks: brainPacks.value }))
  const dirty = computed(() => Boolean(initial.value) && !equal(initial.value, draft.value))
  return {
    resetSource() {
      generation = Symbol()
      slugManuallyEdited = false
      sourceKey.value = undefined
    },
    sourceKey,
    slug,
    displayName,
    brainPacks,
    draft,
    dirty,
    initialize(key: string, source: TenantDraft) {
      if (key === 'new') void preloadTransliteration()
      if (sourceKey.value === key) return
      generation = Symbol()
      slugManuallyEdited = false
      batch(() => {
        sourceKey.value = key
        slug.value = source.slug
        displayName.value = source.displayName
        brainPacks.value = source.brainPacks
        initial.value = source
      })
    },
    setDisplayName(value: string, deriveSlug: boolean) {
      batch(() => {
        displayName.value = value
        if (deriveSlug && !slugManuallyEdited) {
          slug.value = deriveSlugWithTransliteration(value, 63, () => {
            if (!slugManuallyEdited) slug.value = slugFromDisplayName(displayName.value, 63)
          })
        }
      })
    },
    setSlug(value: string) {
      slugManuallyEdited = true
      slug.value = value
    },
    captureSave() {
      const requestedGeneration = generation
      const submitted = { slug: slug.value, displayName: displayName.value, brainPacks: brainPacks.value }
      return (accepted: TenantDraft) => {
        if (generation !== requestedGeneration) return false
        batch(() => {
          if (slug.value === submitted.slug) slug.value = accepted.slug
          if (displayName.value === submitted.displayName) {
            displayName.value = accepted.displayName
          }
          if (equal(brainPacks.value, submitted.brainPacks)) {
            brainPacks.value = accepted.brainPacks
          }
          initial.value = { ...accepted }
        })
        return true
      }
    }
  }
})
