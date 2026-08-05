import { batch, computed, createModel, signal } from '@preact/signals-react'

export type WorkerEnvDraft = {
  name: string
  value: string
  secret: boolean
  description: string
}

export const WorkerEnvEditorModel = createModel(() => {
  const sourceKey = signal<string>()
  const name = signal('')
  const value = signal('')
  const secret = signal(false)
  const description = signal('')
  const initialDraft = signal<WorkerEnvDraft>()
  const validationError = signal<string>()
  const dirty = computed(() => {
    const source = initialDraft.value
    return Boolean(
      source &&
      (name.value !== source.name ||
        value.value !== source.value ||
        secret.value !== source.secret ||
        description.value !== source.description)
    )
  })

  return {
    sourceKey,
    name,
    value,
    secret,
    description,
    dirty,
    validationError,
    initialize(nextSourceKey: string, draft: WorkerEnvDraft) {
      if (sourceKey.value === nextSourceKey) return
      batch(() => {
        sourceKey.value = nextSourceKey
        name.value = draft.name
        value.value = draft.value
        secret.value = draft.secret
        description.value = draft.description
        initialDraft.value = { ...draft }
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
