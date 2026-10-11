import { batch, computed, createModel, signal } from '@preact/signals-react'
import type { WorkerProvider, WorkerProviderCredentialsInput, WorkerProviderKind } from '../api/generated/types.gen'

export type WorkerProviderDraft = {
  providerID: string
  displayName: string
  kind: string
  config: string
  isDefault: boolean
}

export function workerProviderDraft(provider: WorkerProvider): WorkerProviderDraft {
  return {
    providerID: provider.provider_id,
    displayName: provider.display_name,
    kind: provider.kind,
    config: provider.config,
    isDefault: provider.is_default
  }
}

export function newWorkerProviderDraft(kind: WorkerProviderKind): WorkerProviderDraft {
  return { providerID: '', displayName: '', kind: kind.kind, config: kind.example, isDefault: false }
}

export const WorkerProviderEditorModel = createModel(() => {
  const sourceKey = signal<string>()
  const providerID = signal('')
  const displayName = signal('')
  const kind = signal('')
  const config = signal('')
  const isDefault = signal(false)
  // An empty value keeps the stored credential; null removes it on save.
  const credentials = signal<WorkerProviderCredentialsInput>({})
  const initialDraft = signal<WorkerProviderDraft>()
  const draft = computed<WorkerProviderDraft>(() => ({
    providerID: providerID.value,
    displayName: displayName.value,
    kind: kind.value,
    config: config.value,
    isDefault: isDefault.value
  }))
  const dirty = computed(
    () =>
      Boolean(initialDraft.value) &&
      (JSON.stringify(draft.value) !== JSON.stringify(initialDraft.value) ||
        Object.values(credentials.value).some(value => value !== ''))
  )

  return {
    sourceKey,
    providerID,
    displayName,
    kind,
    config,
    isDefault,
    credentials,
    dirty,
    initialize(key: string, source: WorkerProviderDraft) {
      if (sourceKey.value === key) return
      batch(() => {
        sourceKey.value = key
        providerID.value = source.providerID
        displayName.value = source.displayName
        kind.value = source.kind
        config.value = source.config
        isDefault.value = source.isDefault
        credentials.value = {}
        initialDraft.value = source
      })
    },
    selectKind(definition: WorkerProviderKind) {
      batch(() => {
        kind.value = definition.kind
        config.value = definition.example
        credentials.value = {}
      })
    },
    setCredential(name: string, value: string | null) {
      credentials.value = { ...credentials.value, [name]: value }
    },
    markSaved() {
      batch(() => {
        initialDraft.value = draft.value
        credentials.value = {}
      })
    }
  }
})
