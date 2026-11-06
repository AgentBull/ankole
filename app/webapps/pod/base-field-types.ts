import { formatDateTime } from '../common/date-time'
import {
  RiAttachmentLine,
  RiCalendarLine,
  RiCheckboxLine,
  RiFormula,
  RiHashtag,
  RiLink,
  RiListCheck,
  RiText,
  RiTimeLine,
  RiUserLine
} from '@remixicon/react'
import { t } from 'i18next'
import type { BaseField, FieldType, Value } from '@ankole/applet-sdk/types'

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
export const writableField = (field: BaseField) =>
  !['formula', 'auto_number', 'created_at', 'updated_at', 'created_by', 'updated_by'].includes(field.type)
export const SELECT_OPTION_COLORS = [
  'brand',
  'teal',
  'blue',
  'purple',
  'green',
  'orange',
  'yellow',
  'red',
  'gray'
] as const
export type Option = { id: string; name: string; color?: string }
export const fieldOptions = (field: BaseField) =>
  (Array.isArray(field.config.options) ? field.config.options : []) as Option[]
const namesOf = (field: BaseField, values: unknown[]) =>
  values.map(value => fieldOptions(field).find(option => option.id === value)?.name ?? String(value)).join(', ')

export function displayValue(field: BaseField, value: Value) {
  if (value === null) return '—'
  if (['user', 'created_by', 'updated_by'].includes(field.type)) return t('pod.content.people')
  if (field.type === 'link') return t('pod.content.related_records')
  if (field.type === 'checkbox') return value ? '✓' : '—'
  if (field.type === 'select') return Array.isArray(value) ? namesOf(field, value) : namesOf(field, [value])
  if (field.type === 'datetime' || field.type === 'created_at' || field.type === 'updated_at') {
    return formatDateTime(String(value), undefined, 'medium')
  }
  if (Array.isArray(value)) {
    return value.map(item => (typeof item === 'object' && item && 'name' in item ? item.name : item)).join(', ')
  }
  return typeof value === 'object' ? JSON.stringify(value) : String(value)
}

export const fieldIcons = {
  text: RiText,
  number: RiHashtag,
  auto_number: RiHashtag,
  select: RiListCheck,
  datetime: RiCalendarLine,
  checkbox: RiCheckboxLine,
  user: RiUserLine,
  attachment: RiAttachmentLine,
  link: RiLink,
  formula: RiFormula,
  created_at: RiTimeLine,
  updated_at: RiTimeLine,
  created_by: RiUserLine,
  updated_by: RiUserLine
}

export function effectiveFieldType(field: BaseField) {
  if (field.type === 'formula') return String(field.config.result_type ?? 'text')
  if (field.type === 'auto_number') return 'number'
  if (['created_at', 'updated_at'].includes(field.type)) return 'datetime'
  if (['created_by', 'updated_by'].includes(field.type)) return 'person'
  if (field.type === 'checkbox') return 'boolean'
  if (['attachment', 'user', 'link'].includes(field.type) || (field.type === 'select' && field.config.multiple)) {
    return 'array'
  }
  return field.type
}
