import { batch, createModel, signal } from '@preact/signals-react'
import type { Value, Versions } from '@ankole/applet-sdk/types'

/** The edit owns its starting versions and failed value across remote refetches. */
export const DatabaseCellModel = createModel(() => {
  const error = signal<unknown>()
  const attempt = signal<{ value: Value }>()
  const pending = signal(false)
  const generation = signal(0)
  const editingVersions = signal<Versions>()
  return {
    error,
    attempt,
    pending,
    generation,
    begin(versions: Versions) {
      if (!pending.value && !attempt.value && !editingVersions.value) editingVersions.value = versions
    },
    end() {
      if (!pending.value && !attempt.value) editingVersions.value = undefined
    },
    discard() {
      batch(() => {
        attempt.value = undefined
        error.value = undefined
        editingVersions.value = undefined
        generation.value++
      })
    },
    async save(
      fieldID: string,
      next: Value,
      latest: Versions,
      update: (value: Value, versions: Versions) => Promise<unknown>,
      retry = false
    ) {
      if (pending.value) return
      const versions = retry ? latest : (editingVersions.value ?? latest)
      batch(() => {
        pending.value = true
        attempt.value = { value: next }
        error.value = undefined
      })
      try {
        await update(next, Object.hasOwn(versions, fieldID) ? { [fieldID]: versions[fieldID]! } : {})
        batch(() => {
          attempt.value = undefined
          editingVersions.value = undefined
        })
      } catch (failure) {
        error.value = failure
        throw failure
      } finally {
        pending.value = false
      }
    }
  }
})
