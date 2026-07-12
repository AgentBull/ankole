import { batch, createModel, signal } from '@preact/signals-react'

export const CodexAccountEditorModel = createModel(() => {
  const sourceKey = signal<string>()
  const name = signal('')
  const authJSON = signal('')
  const validationError = signal<string>()

  return {
    sourceKey,
    name,
    authJSON,
    validationError,
    initialize(nextSourceKey: string, nextName = '') {
      if (sourceKey.value === nextSourceKey) return
      batch(() => {
        sourceKey.value = nextSourceKey
        name.value = nextName
        authJSON.value = ''
        validationError.value = undefined
      })
    },
    clearValidation() {
      validationError.value = undefined
    }
  }
})
