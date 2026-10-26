import { batch, createModel, signal } from '@preact/signals-react'
import type { RecordData, RecordWrite, Value } from '@ankole/applet-sdk/types'
import { withRecordIDs } from '@ankole/applet-sdk/records'

export const RecordFormModel = createModel(() => {
  const values = signal<RecordData>({})
  const pending = signal(false)
  const uploading = signal(new Set<string>())
  const error = signal<unknown>()
  const generation = signal(0)
  let record: { id?: string; data: RecordData } = { data: {} }
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
    async submit(write: (changes: RecordWrite) => Promise<unknown>) {
      if (pending.value || uploading.value.size) return
      record.data = values.value
      batch(() => {
        pending.value = true
        error.value = undefined
      })
      try {
        await write(withRecordIDs({ creates: [record] }))
        record = { data: {} }
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
