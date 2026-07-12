import { batch, createModel, signal } from '@preact/signals-react'

export type ProviderEditorDraft = {
  providerID: string
  providerKind: string
  baseURL: string
  options: Record<string, string>
}

const emptyDraft = (): ProviderEditorDraft => ({ providerID: '', providerKind: '', baseURL: '', options: {} })

export const ProviderEditorModel = createModel(() => {
  const sourceKey = signal<string>()
  const initial = emptyDraft()
  const providerID = signal(initial.providerID)
  const providerKind = signal(initial.providerKind)
  const baseURL = signal(initial.baseURL)
  const options = signal(initial.options)
  const validationError = signal<string>()

  const apply = (draft: ProviderEditorDraft) => {
    batch(() => {
      providerID.value = draft.providerID
      providerKind.value = draft.providerKind
      baseURL.value = draft.baseURL
      options.value = draft.options
      validationError.value = undefined
    })
  }

  return {
    sourceKey,
    providerID,
    providerKind,
    baseURL,
    options,
    validationError,
    initialize(nextSourceKey: string, draft: ProviderEditorDraft) {
      if (sourceKey.value === nextSourceKey) return
      sourceKey.value = nextSourceKey
      apply(draft)
    },
    changeKind(draft: Omit<ProviderEditorDraft, 'providerID'>) {
      apply({ ...draft, providerID: providerID.value })
    },
    setOption(key: string, value: string) {
      options.value = { ...options.value, [key]: value }
    },
    clearValidation() {
      validationError.value = undefined
    }
  }
})
