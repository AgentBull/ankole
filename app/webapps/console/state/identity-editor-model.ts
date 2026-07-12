import type { JsonObject as JSONObject } from '@pleisto/active-support'
import { batch, createModel, signal } from '@preact/signals-react'

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
  const validationError = signal<string>()

  const apply = (draft: IdentityEditorDraft) => {
    batch(() => {
      adapterID.value = draft.adapterID
      providerID.value = draft.providerID
      enabled.value = draft.enabled
      config.value = draft.config
      validationError.value = undefined
    })
  }

  return {
    sourceKey,
    adapterID,
    providerID,
    enabled,
    config,
    validationError,
    initialize(nextSourceKey: string, draft: IdentityEditorDraft) {
      if (sourceKey.value === nextSourceKey) return
      sourceKey.value = nextSourceKey
      apply(draft)
    },
    changeAdapter(draft: IdentityEditorDraft) {
      apply(draft)
    },
    clearValidation() {
      validationError.value = undefined
    }
  }
})
