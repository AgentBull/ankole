import { batch, computed, createModel, signal } from '@preact/signals-react'
import { match } from '@agentbull/active-support'
import type { BaseField, FieldType } from '@ankole/applet-sdk/types'
import { fieldOptions, type Option } from '../base-field-types'

export function fieldHasStoredValues(
  field: BaseField | undefined,
  recordCount: number | undefined,
  nonEmptyCount: number | undefined
): boolean {
  if (!field) return false
  if (['formula', 'created_at', 'updated_at', 'created_by', 'updated_by'].includes(field.type)) return false
  if (recordCount === 0) return false
  if (nonEmptyCount !== undefined) return nonEmptyCount > 0
  return true
}

export const FieldEditorModel = createModel(() => {
  const original = signal<BaseField>()
  const definitionDirty = signal(false)
  const open = signal(false)
  const name = signal('')
  const description = signal('')
  const type = signal<FieldType>('text')
  const formula = signal('')
  const multiple = signal(false)
  const options = signal<Option[]>([])
  const target = signal('')
  const bidirectional = signal(false)
  const isPrimary = signal(false)
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
    description,
    type,
    formula,
    multiple,
    options,
    target,
    bidirectional,
    isPrimary,
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
    setDescription: (value: string) => {
      description.value = value
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
    setIsPrimary: (value: boolean) => {
      isPrimary.value = value
    },
    setConfirmation: (value: 'delete' | 'change' | 'clear' | undefined) => {
      confirmation.value = value
    },
    load(field?: BaseField) {
      batch(() => {
        original.value = field
        definitionDirty.value = false
        name.value = field?.name ?? ''
        description.value = field?.description ?? ''
        type.value = field?.type ?? 'text'
        formula.value = String(field?.config.source ?? '')
        multiple.value = field?.type === 'link' ? field.config.multiple !== false : field?.config.multiple === true
        options.value = field ? fieldOptions(field) : []
        target.value = String(field?.config.table_id ?? '')
        bidirectional.value = !!field?.config.reverse_field_id || field?.config.bidirectional === true
        isPrimary.value = field?.is_primary ?? false
        baseVersion.value = field?.version ?? 0
        confirmation.value = undefined
      })
    }
  }
})
