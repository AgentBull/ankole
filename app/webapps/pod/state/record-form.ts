import { batch, createModel, signal } from '@preact/signals-react'
import type { RecordData, Value } from '@ankole/applet-sdk/types'

export const RecordFormModel = createModel(() => {
  const values = signal<RecordData>({})
  const pending = signal(false)
  const uploading = signal(new Set<string>())
  const error = signal<unknown>()
  const generation = signal(0)
  return {
    values,
    pending,
    uploading,
    error,
    generation,
    upload(id: string, active: boolean) {
      const next = new Set(uploading.value)
      if (active) next.add(id)
      else next.delete(id)
      uploading.value = next
    },
    change(id: string, value: Value) {
      if (pending.value) return
      batch(() => {
        values.value = { ...values.value, [id]: value }
        error.value = undefined
      })
    },
    async submit(create: (data: RecordData) => Promise<unknown>) {
      if (pending.value || uploading.value.size) return
      const data = values.value
      batch(() => {
        pending.value = true
        error.value = undefined
      })
      try {
        await create(data)
        batch(() => {
          values.value = {}
          generation.value++
        })
      } catch (failure) {
        error.value = failure
      } finally {
        pending.value = false
      }
    }
  }
})
