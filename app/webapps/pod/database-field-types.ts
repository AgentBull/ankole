import { t } from 'i18next'
import type { DatabaseField, FieldType, Value } from '@ankole/applet-sdk/types'

export const fieldTypes: Record<FieldType, string> = {
  get text() {
    return t('pod.content.text')
  },
  get number() {
    return t('pod.content.number')
  },
  get select() {
    return t('pod.content.select')
  },
  get datetime() {
    return t('pod.content.date_and_time')
  },
  get checkbox() {
    return t('pod.content.checkbox')
  },
  get user() {
    return t('pod.content.people')
  },
  get attachment() {
    return t('pod.content.attachment')
  },
  get auto_number() {
    return t('pod.content.auto_number')
  },
  get link() {
    return t('pod.content.relation')
  },
  get formula() {
    return t('pod.content.formula')
  },
  get created_at() {
    return t('pod.content.created_time')
  },
  get updated_at() {
    return t('pod.content.last_edited_time')
  },
  get created_by() {
    return t('pod.content.created_by')
  },
  get updated_by() {
    return t('pod.content.last_edited_by')
  }
}
export const writableField = (field: DatabaseField, readonlyFieldIDs: string[] = []) =>
  !['formula', 'auto_number', 'created_at', 'updated_at', 'created_by', 'updated_by'].includes(field.type) &&
  !readonlyFieldIDs.includes(field.id)
export type Option = { id: string; name: string }
export const fieldOptions = (field: DatabaseField) =>
  (Array.isArray(field.config.options) ? field.config.options : []) as Option[]
const namesOf = (field: DatabaseField, values: unknown[]) =>
  values.map(value => fieldOptions(field).find(option => option.id === value)?.name ?? String(value)).join(', ')

export function displayValue(field: DatabaseField, value: Value) {
  if (value === null) return '—'
  if (['user', 'created_by', 'updated_by'].includes(field.type)) return t('pod.content.people')
  if (field.type === 'link') return t('pod.content.related_records')
  if (field.type === 'checkbox') return value ? '✓' : '—'
  if (field.type === 'select') return Array.isArray(value) ? namesOf(field, value) : namesOf(field, [value])
  if (field.type === 'datetime' || field.type === 'created_at' || field.type === 'updated_at') {
    return new Date(String(value)).toLocaleString()
  }
  if (Array.isArray(value)) {
    return value.map(item => (typeof item === 'object' && item && 'name' in item ? item.name : item)).join(', ')
  }
  return typeof value === 'object' ? JSON.stringify(value) : String(value)
}
