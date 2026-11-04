import { dateTimeLocalValue } from '../../common/date-time'
import { batch, createModel, signal } from '@preact/signals-react'
import type { FieldType, Value } from '@ankole/applet-sdk/types'

function formatFieldInput(value: Value, type: FieldType) {
  if (value === null) return ''
  if (type !== 'datetime') return String(value)
  return dateTimeLocalValue(String(value)).slice(0, 16)
}
export const FieldInputModel = createModel(() => {
  const draft = signal('')
  const dirty = signal(false)
  const cancelled = signal(false)
  const error = signal<unknown>()
  const picker = signal(false)
  return {
    draft,
    dirty,
    cancelled,
    error,
    picker,
    load(value: Value, type: FieldType) {
      if (!dirty.value) draft.value = formatFieldInput(value, type)
    },
    edit(value: string) {
      batch(() => {
        dirty.value = true
        error.value = undefined
        draft.value = value
      })
    },
    cancel(value: Value, type: FieldType) {
      batch(() => {
        cancelled.value = true
        dirty.value = false
        error.value = undefined
        draft.value = formatFieldInput(value, type)
      })
    }
  }
})
