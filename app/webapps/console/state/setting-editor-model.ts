import { batch, computed, createModel, signal } from '@preact/signals-react'

export function settingDecryptedDraft(value: unknown): string {
  return typeof value === 'string' ? value : (JSON.stringify(value) ?? '')
}

export function encryptedSettingValue(text: string): unknown {
  try {
    const parsed = JSON.parse(text) as unknown
    if (parsed !== null && typeof parsed === 'object') return parsed
  } catch {
    // An opaque secret does not have to be JSON.
  }
  return text
}

export const SettingEditorModel = createModel(() => {
  const sourceKey = signal<string>()
  const text = signal('')
  const validationError = signal<string>()
  const initialText = signal('')
  const dirty = computed(() => text.value !== initialText.value)

  return {
    sourceKey,
    text,
    validationError,
    dirty,
    initialize(nextSourceKey: string, nextText: string) {
      if (sourceKey.value === nextSourceKey) return
      batch(() => {
        sourceKey.value = nextSourceKey
        text.value = nextText
        initialText.value = nextText
        validationError.value = undefined
      })
    },
    reveal(nextText: string) {
      batch(() => {
        text.value = nextText
        initialText.value = nextText
      })
    },
    resetSource() {
      batch(() => {
        sourceKey.value = undefined
        text.value = ''
        initialText.value = ''
        validationError.value = undefined
      })
    },
    clearValidation() {
      validationError.value = undefined
    }
  }
})
