import { batch, createModel, signal } from '@preact/signals-react'

export type AgentEditorDraft = {
  uid: string
  displayName: string
  avatarURL: string
  role: string
  options: string
}

export const AgentEditorModel = createModel(() => {
  const sourceKey = signal<string>()
  const uid = signal('')
  const displayName = signal('')
  const avatarURL = signal('')
  const role = signal('Research Analyst')
  const options = signal('{}')
  const validationError = signal<string>()

  return {
    sourceKey,
    uid,
    displayName,
    avatarURL,
    role,
    options,
    validationError,
    initialize(nextSourceKey: string, draft: AgentEditorDraft) {
      if (sourceKey.value === nextSourceKey) return
      batch(() => {
        sourceKey.value = nextSourceKey
        uid.value = draft.uid
        displayName.value = draft.displayName
        avatarURL.value = draft.avatarURL
        role.value = draft.role
        options.value = draft.options
        validationError.value = undefined
      })
    },
    clearValidation() {
      validationError.value = undefined
    }
  }
})
