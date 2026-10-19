import { batch, computed, createModel, signal } from '@preact/signals-react'

export type WorkerEnvDraft = {
  name: string
  value: string
  secret: boolean
  description: string
}

export const WorkerEnvEditorModel = createModel(() => {
  let generation = Symbol()
  let valueRevision = 0
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
      generation = Symbol()
      valueRevision++
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
      generation = Symbol()
      valueRevision++
      sourceKey.value = undefined
    },
    captureReveal() {
      const requestedGeneration = generation
      const requestedValue = value.value
      const requestedRevision = valueRevision
      return (revealed: string) => {
        if (
          generation !== requestedGeneration ||
          valueRevision !== requestedRevision ||
          value.value !== requestedValue
        ) {
          return false
        }
        batch(() => {
          value.value = revealed
          if (initialDraft.value?.value === requestedValue) {
            initialDraft.value = { ...initialDraft.value, value: revealed }
          }
        })
        return true
      }
    },
    setValue(next: string) {
      valueRevision++
      value.value = next
    },
    captureSave() {
      const requestedGeneration = generation
      const submitted = { name: name.value, value: value.value, secret: secret.value, description: description.value }
      return (accepted: WorkerEnvDraft) => {
        if (generation !== requestedGeneration) return false
        valueRevision++
        batch(() => {
          if (name.value === submitted.name) name.value = accepted.name
          if (value.value === submitted.value) value.value = accepted.value
          if (secret.value === submitted.secret) secret.value = accepted.secret
          if (description.value === submitted.description) description.value = accepted.description
          initialDraft.value = { ...accepted }
        })
        return true
      }
    },
    clearValidation() {
      validationError.value = undefined
    }
  }
})
