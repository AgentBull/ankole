import { computed, createModel, signal } from '@preact/signals-react'
import { preloadTransliteration, spaceSlugFromName, validTenantSlug } from '../../common/tenant-slug'

export const BrainPacksStepModel = createModel(() => {
  const sourceKey = signal<string>()
  const selectedPacks = signal<ReadonlySet<string>>(new Set())
  const companyName = signal('')
  const customSlug = signal<string>()
  const editingSlug = signal(false)
  const transliteration = signal<'loading' | 'ready' | 'unavailable'>('loading')
  void preloadTransliteration().then(
    () => {
      transliteration.value = 'ready'
    },
    () => {
      transliteration.value = 'unavailable'
    }
  )
  const baseSlug = computed(() =>
    transliteration.value === 'ready' ? spaceSlugFromName(companyName.value.trim()) : ''
  )
  const slug = computed(() => customSlug.value ?? baseSlug.value)

  return {
    sourceKey,
    selectedPacks,
    companyName,
    customSlug,
    editingSlug,
    transliteration,
    slug,
    initialize(nextSourceKey: string, selected: string[], organization: { displayName: string; slug: string }) {
      if (sourceKey.value === nextSourceKey) return
      sourceKey.value = nextSourceKey
      selectedPacks.value = new Set(selected)
      const initial = organization.slug === 'default' && organization.displayName === 'Default'
      companyName.value = initial ? '' : organization.displayName
      customSlug.value = initial ? undefined : organization.slug
    },
    setPackSelected(name: string, selected: boolean) {
      const next = new Set(selectedPacks.value)
      selected ? next.add(name) : next.delete(name)
      selectedPacks.value = next
    },
    editSlug(current: string) {
      customSlug.value = current
      editingSlug.value = true
    },
    canSubmit(): boolean {
      return companyName.value.trim() !== '' && validTenantSlug(slug.value)
    },
    submission() {
      return {
        packs: [...selectedPacks.value],
        displayName: companyName.value.trim(),
        slug: slug.value
      }
    }
  }
})
