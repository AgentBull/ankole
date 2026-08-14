import type { JsonObject as JSONObject } from '@agentbull/active-support'
import { batch, computed, createModel, signal } from '@preact/signals-react'

export type IdentityEditorDraft = {
  adapterID: string
  providerID: string
  enabled: boolean
  config: JSONObject
}

export const IdentityEditorModel = createModel(() => {
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
    sourceKey,
    adapterID,
    providerID,
    enabled,
    config,
    dirty,
    validationError,
    initialize(nextSourceKey: string, draft: IdentityEditorDraft) {
      if (sourceKey.value === nextSourceKey) return
      sourceKey.value = nextSourceKey
      apply(draft)
    },
    changeAdapter(draft: IdentityEditorDraft) {
      apply(draft)
    },
    /** Rebaselines the draft to the persisted provider, so a save clears dirty without leaving the page. */
    markSaved(draft: IdentityEditorDraft) {
      apply(draft)
    },
    clearValidation() {
      validationError.value = undefined
    }
  }
})
