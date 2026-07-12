import { batch, createModel, signal } from '@preact/signals-react'

export const SettingEditorModel = createModel(() => {
  const sourceKey = signal<string>()
  const text = signal('')
  const validationError = signal<string>()

  return {
    sourceKey,
    text,
    validationError,
    initialize(nextSourceKey: string, nextText: string) {
      if (sourceKey.value === nextSourceKey) return
      batch(() => {
        sourceKey.value = nextSourceKey
        text.value = nextText
        validationError.value = undefined
      })
    },
    resetSource() {
      sourceKey.value = undefined
    },
    clearValidation() {
      validationError.value = undefined
    }
  }
})
