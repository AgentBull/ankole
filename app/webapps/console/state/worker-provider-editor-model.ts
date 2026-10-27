import { equal } from '@agentbull/active-support'
import { batch, computed, createModel, signal } from '@preact/signals-react'
import type { WorkerProviderKind } from '../api/configuration-types'
import { type Flat, fromDocument } from '../api/json-api'
import type { WorkerProvider as WorkerProviderResource } from '../api/v2-site/generated/types.gen'
import { deriveSlugWithTransliteration, preloadTransliteration, slugFromDisplayName } from './agent-editor-model'

/**
 * A Worker provider of the site API. The API sends the calculated fields as
 * default fields of each record, but its schema marks them optional.
 */
export type WorkerProvider = Flat<WorkerProviderResource> & {
  agent_count: number
  selectable: boolean
  stored_credentials: string[]
}

/** Text replaces a stored credential, an empty string keeps it, and null removes it. */
export type WorkerProviderCredentialsInput = Record<string, string | null>

/** Changes a provider document, or a list document, to the provider records. */
export function workerProviders(document: { data?: WorkerProviderResource[] }): WorkerProvider[] {
  return fromDocument(document) as WorkerProvider[]
}

export function workerProvider(document: { data?: WorkerProviderResource }): WorkerProvider {
  return fromDocument(document) as WorkerProvider
}

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
  let generation = Symbol()
  let providerIDManuallyEdited = false
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
      (!equal(draft.value, initialDraft.value) || Object.values(credentials.value).some(value => value !== ''))
  )

  return {
    resetSource() {
      generation = Symbol()
      providerIDManuallyEdited = false
      sourceKey.value = undefined
    },
    sourceKey,
    providerID,
    displayName,
    kind,
    config,
    isDefault,
    credentials,
    dirty,
    initialize(key: string, source: WorkerProviderDraft) {
      if (key === 'new') void preloadTransliteration()
      if (sourceKey.value === key) return
      generation = Symbol()
      providerIDManuallyEdited = false
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
    setDisplayName(value: string, deriveProviderID: boolean) {
      batch(() => {
        displayName.value = value
        if (deriveProviderID && !providerIDManuallyEdited) {
          providerID.value = deriveSlugWithTransliteration(value, 63, () => {
            if (!providerIDManuallyEdited) providerID.value = slugFromDisplayName(displayName.value, 63)
          })
        }
      })
    },
    setProviderID(value: string) {
      providerIDManuallyEdited = true
      providerID.value = value
    },
    selectKind(definition: WorkerProviderKind) {
      generation = Symbol()
      batch(() => {
        kind.value = definition.kind
        config.value = definition.example
        credentials.value = {}
      })
    },
    setCredential(name: string, value: string | null) {
      credentials.value = { ...credentials.value, [name]: value }
    },
    captureSave() {
      const requestedGeneration = generation
      const submitted = {
        providerID: providerID.value,
        displayName: displayName.value,
        kind: kind.value,
        config: config.value,
        isDefault: isDefault.value
      }
      const submittedCredentials = { ...credentials.value }
      return (accepted: WorkerProviderDraft) => {
        if (generation !== requestedGeneration) return false
        batch(() => {
          if (providerID.value === submitted.providerID) {
            providerID.value = accepted.providerID
          }
          if (displayName.value === submitted.displayName) {
            displayName.value = accepted.displayName
          }
          if (kind.value === submitted.kind) kind.value = accepted.kind
          if (config.value === submitted.config) config.value = accepted.config
          if (isDefault.value === submitted.isDefault) {
            isDefault.value = accepted.isDefault
          }
          initialDraft.value = { ...accepted }
          credentials.value = Object.fromEntries(
            Object.entries(credentials.value).filter(
              ([key, value]) => !(key in submittedCredentials) || value !== submittedCredentials[key]
            )
          )
        })
        return true
      }
    }
  }
})
