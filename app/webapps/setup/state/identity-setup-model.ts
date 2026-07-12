import type { JsonObject as JSONObject } from '@pleisto/active-support'
import { batch, createModel, signal } from '@preact/signals-react'

export type IdentitySetupDraft = {
  adapterID: string
  providerID: string
  config: JSONObject
}

export const IdentitySetupModel = createModel(() => {
  const sourceKey = signal<string>()
  const adapterID = signal('')
  const providerID = signal('')
  const config = signal<JSONObject>({})
  const validationError = signal<string>()

  const apply = (draft: IdentitySetupDraft) => {
    batch(() => {
      adapterID.value = draft.adapterID
      providerID.value = draft.providerID
      config.value = draft.config
      validationError.value = undefined
    })
  }

  return {
    sourceKey,
    adapterID,
    providerID,
    config,
    validationError,
    initialize(nextSourceKey: string, draft: IdentitySetupDraft) {
      if (sourceKey.value === nextSourceKey) return
      sourceKey.value = nextSourceKey
      apply(draft)
    },
    changeAdapter(draft: IdentitySetupDraft) {
      apply(draft)
    },
    setConfig(nextConfig: JSONObject) {
      config.value = nextConfig
    },
    setValidationError(error?: string) {
      validationError.value = error
    },
    submission(): IdentitySetupDraft {
      return {
        adapterID: adapterID.value,
        providerID: providerID.value,
        config: config.value
      }
    }
  }
})
