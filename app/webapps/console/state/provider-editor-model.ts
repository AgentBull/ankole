import { batch, computed, createModel, signal } from '@preact/signals-react'

export type ProviderEditorDraft = {
  providerID: string
  providerKind: string
  baseURL: string
  options: Record<string, string>
}

const emptyDraft = (): ProviderEditorDraft => ({ providerID: '', providerKind: '', baseURL: '', options: {} })

export function nextProviderID(providerKind: string, existingProviderIDs: Iterable<string>): string {
  const existing = new Set(existingProviderIDs)
  if (!existing.has(providerKind)) return providerKind

  let suffix = 2
  while (existing.has(`${providerKind}-${suffix}`)) suffix += 1
  return `${providerKind}-${suffix}`
}

export const ProviderEditorModel = createModel(() => {
  const sourceKey = signal<string>()
  const initial = emptyDraft()
  const providerID = signal(initial.providerID)
  const providerKind = signal(initial.providerKind)
  const baseURL = signal(initial.baseURL)
  const options = signal(initial.options)
  const initialDraft = signal<ProviderEditorDraft>()
  const validationError = signal<string>()
  const dirty = computed(() => {
    const source = initialDraft.value
    return Boolean(
      source &&
      (providerID.value !== source.providerID ||
        providerKind.value !== source.providerKind ||
        baseURL.value !== source.baseURL ||
        JSON.stringify(options.value) !== JSON.stringify(source.options))
    )
  })

  const apply = (draft: ProviderEditorDraft) => {
    batch(() => {
      providerID.value = draft.providerID
      providerKind.value = draft.providerKind
      baseURL.value = draft.baseURL
      options.value = draft.options
      initialDraft.value = {
        ...draft,
        options: { ...draft.options }
      }
      validationError.value = undefined
    })
  }

  return {
    sourceKey,
    providerID,
    providerKind,
    baseURL,
    options,
    dirty,
    validationError,
    initialize(nextSourceKey: string, draft: ProviderEditorDraft) {
      if (sourceKey.value === nextSourceKey) return
      sourceKey.value = nextSourceKey
      apply(draft)
    },
    changeKind(draft: ProviderEditorDraft) {
      apply(draft)
    },
    setOption(key: string, value: string) {
      options.value = { ...options.value, [key]: value }
    },
    clearValidation() {
      validationError.value = undefined
    },
    markSaved() {
      initialDraft.value = {
        providerID: providerID.value,
        providerKind: providerKind.value,
        baseURL: baseURL.value,
        options: { ...options.value }
      }
    }
  }
})
