import type { JsonObject as JSONObject } from '@pleisto/active-support'
import { batch, createModel, signal } from '@preact/signals-react'
import type { SignalBindingWriteRequest } from '../api/generated/types.gen'

export type GroupMessageMode = NonNullable<SignalBindingWriteRequest['group_message_mode']>

export type SignalBindingEditorDraft = {
  adapterID: string
  name: string
  groupMessageMode: GroupMessageMode | ''
  config: JSONObject
}

export const SignalBindingEditorModel = createModel(() => {
  const sourceKey = signal<string>()
  const adapterID = signal('')
  const name = signal('')
  const groupMessageMode = signal<GroupMessageMode | ''>('')
  const config = signal<JSONObject>({})
  const validationError = signal<string>()

  const apply = (draft: SignalBindingEditorDraft) => {
    batch(() => {
      adapterID.value = draft.adapterID
      name.value = draft.name
      groupMessageMode.value = draft.groupMessageMode
      config.value = draft.config
      validationError.value = undefined
    })
  }

  return {
    sourceKey,
    adapterID,
    name,
    groupMessageMode,
    config,
    validationError,
    initialize(nextSourceKey: string, draft: SignalBindingEditorDraft) {
      if (sourceKey.value === nextSourceKey) return
      sourceKey.value = nextSourceKey
      apply(draft)
    },
    changeAdapter(draft: SignalBindingEditorDraft) {
      apply(draft)
    },
    clearValidation() {
      validationError.value = undefined
    }
  }
})
