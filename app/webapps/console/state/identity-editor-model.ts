import type { JsonObject as JSONObject } from '@agentbull/active-support'
import { batch, computed, createModel, signal } from '@preact/signals-react'

export type IdentityEditorDraft = {
  adapterID: string
  providerID: string
  enabled: boolean
  config: JSONObject
}

export const IdentityEditorModel = createModel(() => {
  let generation = Symbol()
  const sourceKey = signal<string>()
  const adapterID = signal('')
  const providerID = signal('')
  const enabled = signal(true)
  const config = signal<JSONObject>({})
  const initialDraft = signal<IdentityEditorDraft>()
  const validationError = signal<string>()
  const dirty = computed(() => {
    const source = initialDraft.value
    return Boolean(
      source &&
      (adapterID.value !== source.adapterID ||
        providerID.value !== source.providerID ||
        enabled.value !== source.enabled ||
        JSON.stringify(config.value) !== JSON.stringify(source.config))
    )
  })

  const apply = (draft: IdentityEditorDraft) => {
    batch(() => {
      adapterID.value = draft.adapterID
      providerID.value = draft.providerID
      enabled.value = draft.enabled
      config.value = draft.config
      initialDraft.value = { ...draft, config: { ...draft.config } }
      validationError.value = undefined
    })
  }

  return {
    resetSource() {
      generation = Symbol()
      sourceKey.value = undefined
    },
    sourceKey,
    adapterID,
    providerID,
    enabled,
    config,
    dirty,
    validationError,
    initialize(nextSourceKey: string, draft: IdentityEditorDraft) {
      if (sourceKey.value === nextSourceKey) return
      generation = Symbol()
      sourceKey.value = nextSourceKey
      apply(draft)
    },
    changeAdapter(draft: IdentityEditorDraft) {
      generation = Symbol()
      apply(draft)
    },
    /** Confirms the submitted fields and keeps edits made while saving. */
    captureSave() {
      const requestedGeneration = generation
      const submittedValidation = validationError.value
      const submitted = {
        adapterID: adapterID.value,
        providerID: providerID.value,
        enabled: enabled.value,
        config: config.value
      }
      return (accepted: IdentityEditorDraft) => {
        if (generation !== requestedGeneration) return false
        batch(() => {
          if (JSON.stringify(adapterID.value) === JSON.stringify(submitted.adapterID)) {
            adapterID.value = accepted.adapterID
          }
          if (JSON.stringify(providerID.value) === JSON.stringify(submitted.providerID)) {
            providerID.value = accepted.providerID
          }
          if (JSON.stringify(enabled.value) === JSON.stringify(submitted.enabled)) enabled.value = accepted.enabled
          if (JSON.stringify(config.value) === JSON.stringify(submitted.config)) config.value = accepted.config
          initialDraft.value = { ...accepted }
          if (validationError.value === submittedValidation) validationError.value = undefined
        })
        return true
      }
    },
    clearValidation() {
      validationError.value = undefined
    }
  }
})
