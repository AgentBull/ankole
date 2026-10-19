import { batch, computed, createModel, signal } from '@preact/signals-react'
import { match } from '@agentbull/active-support'
import type { DatabaseField, FieldType } from '@ankole/applet-sdk/types'
import { fieldOptions, type Option } from '../database-field-types'

export const FieldEditorModel = createModel(() => {
  const original = signal<DatabaseField>()
  const definitionDirty = signal(false)
  const open = signal(false)
  const name = signal('')
  const type = signal<FieldType>('text')
  const formula = signal('')
  const multiple = signal(false)
  const options = signal<Option[]>([])
  const target = signal('')
  const bidirectional = signal(false)
  const baseVersion = signal(0)
  const confirmation = signal<'delete' | 'change' | 'clear'>()
  const config = computed(() =>
    !definitionDirty.value && original.value
      ? original.value.config
      : match(type.value)
          .with('formula', () => ({
            ...(original.value?.type === 'formula' ? original.value.config : {}),
            source: formula.value
          }))
          .with('select', () => ({
            ...(original.value?.type === 'select' ? original.value.config : {}),
            multiple: multiple.value,
            options: options.value.filter(option => option.name.trim())
          }))
          .with('link', () => ({
            ...(original.value?.type === 'link' ? original.value.config : {}),
            table_id: target.value,
            multiple: multiple.value,
            bidirectional: bidirectional.value
          }))
          .otherwise(() => (type.value === original.value?.type ? original.value.config : {}))
  )
  const changesValues = computed(() => {
    const field = original.value
    return (
      !!field &&
      (type.value !== field.type ||
        (type.value === 'select' &&
          (multiple.value !== (field.config.multiple === true) ||
            fieldOptions(field).some(
              option => !options.value.some(next => next.id === option.id && next.name.trim())
            ))) ||
        (type.value === 'link' &&
          (target.value !== String(field.config.table_id ?? '') ||
            multiple.value !== (field.config.multiple !== false) ||
            bidirectional.value !== (!!field.config.reverse_field_id || field.config.bidirectional === true))))
    )
  })
  return {
    open,
    name,
    type,
    formula,
    multiple,
    options,
    target,
    bidirectional,
    baseVersion,
    confirmation,
    config,
    changesValues,
    setOpen: (value: boolean) => {
      open.value = value
    },
    setName: (value: string) => {
      name.value = value
    },
    setType: (value: FieldType) => {
      type.value = value
      definitionDirty.value = true
    },
    setFormula: (value: string) => {
      formula.value = value
      definitionDirty.value = true
    },
    setMultiple: (value: boolean) => {
      multiple.value = value
      definitionDirty.value = true
    },
    setOptions: (value: Option[]) => {
      options.value = value
      definitionDirty.value = true
    },
    setTarget: (value: string) => {
      target.value = value
      definitionDirty.value = true
    },
    setBidirectional: (value: boolean) => {
      bidirectional.value = value
      definitionDirty.value = true
    },
    setConfirmation: (value: 'delete' | 'change' | 'clear' | undefined) => {
      confirmation.value = value
    },
    load(field?: DatabaseField) {
      batch(() => {
        original.value = field
        definitionDirty.value = false
        name.value = field?.name ?? ''
        type.value = field?.type ?? 'text'
        formula.value = String(field?.config.source ?? '')
        multiple.value = field?.type === 'link' ? field.config.multiple !== false : field?.config.multiple === true
        options.value = field ? fieldOptions(field) : []
        target.value = String(field?.config.table_id ?? '')
        bidirectional.value = !!field?.config.reverse_field_id || field?.config.bidirectional === true
        baseVersion.value = field?.version ?? 0
        confirmation.value = undefined
      })
    }
  }
})
