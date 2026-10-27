import { t } from 'i18next'
import { isEqual } from '@agentbull/active-support'
import type {
  AggregateQuery,
  AggregateResult,
  Condition,
  BaseField,
  BaseRecord,
  Filter,
  GroupBy,
  RecordQuery,
  Value
} from '@ankole/applet-sdk/types'

export function fieldValue(record: BaseRecord, field: BaseField): Value {
  const value = ['created_at', 'updated_at', 'created_by', 'updated_by'].includes(field.type)
    ? (record[field.type as 'created_at'] ?? null)
    : (record.data[field.id] ?? null)
  return value === '' || (Array.isArray(value) && !value.length) ? null : value
}

export function principalUID(value: Value | undefined): string | null {
  if (value === null || value === undefined) return null
  const raw =
    typeof value === 'object' && !Array.isArray(value) && 'uid' in value
      ? String(value.uid ?? '')
      : typeof value === 'string'
        ? value.includes(':principal/')
          ? value.slice(value.indexOf(':principal/') + ':principal/'.length)
          : value
        : ''
  const normalized = raw.trim().toLowerCase()
  return normalized || null
}

/** PostgreSQL C collation compares Unicode scalar values in UTF-8 order. */
function compareValues(a: Value, b: Value): number {
  if (a === b) return 0
  if (a === null) return 1
  if (b === null) return -1
  if (typeof a === 'number' && typeof b === 'number') return a < b ? -1 : 1
  if (typeof a === 'boolean' && typeof b === 'boolean') return Number(a) - Number(b)
  if (Array.isArray(a) || Array.isArray(b) || typeof a === 'object' || typeof b === 'object') return compareJSONB(a, b)
  const left = Array.from(typeof a === 'string' ? a : JSON.stringify(a))
  const right = Array.from(typeof b === 'string' ? b : JSON.stringify(b))
  for (let i = 0; i < Math.min(left.length, right.length); i++) {
    const difference = left[i]!.codePointAt(0)! - right[i]!.codePointAt(0)!
    if (difference) return difference
  }
  return left.length - right.length
}

/** JSONB compares container size before elements, and stores object keys by UTF-8 byte length. */
function compareJSONB(a: unknown, b: unknown): number {
  const rank = (value: unknown) =>
    value === null
      ? 0
      : typeof value === 'string'
        ? 1
        : typeof value === 'number'
          ? 2
          : typeof value === 'boolean'
            ? 3
            : Array.isArray(value)
              ? 4
              : 5
  const type = rank(a) - rank(b)
  if (type) return type
  if (a === b) return 0
  if (Array.isArray(a) && Array.isArray(b)) {
    if (a.length !== b.length) return a.length - b.length
    for (let i = 0; i < a.length; i++) {
      const difference = compareJSONB(a[i], b[i])
      if (difference) return difference
    }
    return 0
  }
  if (a && b && typeof a === 'object' && typeof b === 'object') {
    const encoder = new TextEncoder()
    const keys = (value: object) =>
      Object.keys(value).sort((a, b) => encoder.encode(a).length - encoder.encode(b).length || compareValues(a, b))
    const left = keys(a),
      right = keys(b)
    if (left.length !== right.length) return left.length - right.length
    for (let i = 0; i < left.length; i++) {
      const difference =
        compareValues(left[i]!, right[i]!) ||
        compareJSONB((a as Record<string, unknown>)[left[i]!], (b as Record<string, unknown>)[right[i]!])
      if (difference) return difference
    }
    return 0
  }
  return compareValues(a as Value, b as Value)
}

function matches(value: Value, condition: Condition, field?: BaseField): boolean {
  if (condition.operator === 'is_empty') return value === null
  if (condition.operator === 'is_not_empty') return value !== null
  // SQL comparisons with NULL never select a row.
  if (value === null || condition.value === null || condition.value === undefined) return false
  if (condition.operator === 'is' && field && (field.type === 'created_by' || field.type === 'updated_by')) {
    const left = principalUID(value),
      right = principalUID(condition.value)
    return left !== null && left === right
  }
  switch (condition.operator) {
    case 'is':
      return isEqual(value, condition.value)
    case 'contains':
      return Array.isArray(value) && value.some(item => jsonbContains(item, condition.value))
    case 'text_contains':
      return typeof value === 'string' && asciiFold(value).includes(asciiFold(String(condition.value)))
    case 'gt':
      return compareValues(value, condition.value) > 0
    case 'gte':
      return compareValues(value, condition.value) >= 0
    case 'lt':
      return compareValues(value, condition.value) < 0
    case 'lte':
      return compareValues(value, condition.value) <= 0
  }
}

const asciiFold = (value: string) => value.replace(/[A-Z]/g, character => character.toLowerCase())

function jsonbContains(value: unknown, contained: unknown): boolean {
  if (Array.isArray(value) && Array.isArray(contained)) {
    return contained.every(item => value.some(candidate => jsonbContains(candidate, item)))
  }
  if (
    value &&
    contained &&
    typeof value === 'object' &&
    typeof contained === 'object' &&
    !Array.isArray(value) &&
    !Array.isArray(contained)
  ) {
    return Object.entries(contained).every(
      ([key, item]) => Object.hasOwn(value, key) && jsonbContains((value as Record<string, unknown>)[key], item)
    )
  }
  return isEqual(value, contained)
}

function filterRecords(records: BaseRecord[], fields: BaseField[], filter?: Filter) {
  if (!filter?.conditions.length) return records
  const byID = new Map(fields.map(field => [field.id, field]))
  return records.filter(record => {
    const test = (condition: Condition) => {
      const field = byID.get(condition.field_id)
      if (!field) throw new Error(t('pod.content.the_filter_field_was_deleted_update_your_filters'))
      return matches(fieldValue(record, field), condition, field)
    }
    return filter.conjunction === 'and' ? filter.conditions.every(test) : filter.conditions.some(test)
  })
}

export function queryLocalRecords(records: BaseRecord[], fields: BaseField[], query: RecordQuery): BaseRecord[] {
  const byID = new Map(fields.map(field => [field.id, field]))
  const selected = filterRecords(records, fields, query.filter).filter(record => {
    if (query.ids && !query.ids.includes(record.id)) return false
    if (!query.group) return true
    const field = fields.find(field => field.id === query.group!.field_id)
    if (!field) throw new Error(t('pod.content.the_grouping_field_was_deleted'))
    const expected =
      query.group.value_json !== undefined
        ? query.group.value_json === null
          ? null
          : (JSON.parse(query.group.value_json) as Value)
        : (query.group.value ?? null)
    const actual = fieldValue(record, field)
    if (expected === null) return actual === null
    if (field.type === 'created_by' || field.type === 'updated_by') {
      const actualUID = principalUID(actual),
        expectedUID = principalUID(expected)
      return actualUID !== null && actualUID === expectedUID
    }
    return Array.isArray(actual) ? actual.some(item => isEqual(item, expected)) : isEqual(actual, expected)
  })
  return [...selected].sort((a, b) => {
    for (const sort of query.sort ?? []) {
      const field = byID.get(sort.field_id)
      if (!field) throw new Error(t('pod.content.the_sort_field_was_deleted_update_your_sort_settings'))
      const left = fieldValue(a, field),
        right = fieldValue(b, field)
      const compared = compareValues(left, right)
      // NULLS LAST applies in both directions.
      if (compared) return left === null || right === null ? compared : sort.direction === 'desc' ? -compared : compared
    }
    return compareValues(a.id, b.id)
  })
}

function bucket(value: Value, group: GroupBy, timezone: string): Value {
  if (!group.bucket || value === null) return value
  const date = new Date(String(value))
  if (!Number.isFinite(date.getTime())) return null
  const parts = new Intl.DateTimeFormat('en-CA', {
    timeZone: timezone,
    year: 'numeric',
    month: '2-digit',
    day: '2-digit'
  }).formatToParts(date)
  const part = (name: Intl.DateTimeFormatPartTypes) => parts.find(part => part.type === name)?.value ?? ''
  const year = part('year'),
    month = part('month'),
    day = part('day')
  switch (group.bucket) {
    case 'year':
      return year
    case 'quarter':
      return `${year}-Q${Math.ceil(Number(month) / 3)}`
    case 'month':
      return `${year}-${month}`
    case 'day':
      return `${year}-${month}-${day}`
    case 'week': {
      const monday = new Date(`${year}-${month}-${day}T00:00:00Z`)
      monday.setUTCDate(monday.getUTCDate() - ((monday.getUTCDay() + 6) % 7))
      return monday.toISOString().slice(0, 10)
    }
  }
}

export function aggregateLocalRecords(
  records: BaseRecord[],
  fields: BaseField[],
  query: AggregateQuery,
  dataVersion: number,
  timezone = 'UTC'
): AggregateResult {
  const byID = new Map(fields.map(field => [field.id, field]))
  const groups = new Map<string, { values: Value[]; records: BaseRecord[] }>()
  const groupBy = query.group_by ?? []
  if (groupBy.length > 2) throw new Error(t('pod.content.you_can_group_by_up_to_two_fields'))
  if (!groupBy.length) groups.set('[]', { values: [], records: [] })
  for (const record of filterRecords(records, fields, query.filter)) {
    let combinations: Value[][] = [[]]
    for (const group of groupBy) {
      const field = byID.get(group.field_id)
      if (!field) throw new Error(t('pod.content.the_grouping_field_was_deleted'))
      const value = fieldValue(record, field)
      const values =
        Array.isArray(value) && value.length
          ? (value as Value[])
          : [Array.isArray(value) ? null : bucket(value, group, timezone)]
      combinations = combinations.flatMap(combination => values.map(item => [...combination, item]))
    }
    for (const values of combinations) {
      const key = JSON.stringify(values)
      const group = groups.get(key) ?? { values, records: [] }
      group.records.push(record)
      groups.set(key, group)
    }
  }
  return {
    data_version: dataVersion,
    groups: [...groups.values()].map(group => ({
      values: group.values,
      metrics: Object.fromEntries(
        query.metrics.map(metric => {
          const field = metric.field_id ? byID.get(metric.field_id) : undefined
          const values = field
            ? group.records.map(record => fieldValue(record, field)).filter(value => value !== null)
            : []
          const numeric = values.filter(value => typeof value === 'number') as number[]
          const value =
            metric.operation === 'count'
              ? metric.field_id
                ? values.length
                : group.records.length
              : !values.length
                ? null
                : metric.operation === 'sum'
                  ? numeric.reduce((sum, value) => sum + value, 0)
                  : metric.operation === 'avg'
                    ? numeric.reduce((sum, value) => sum + value, 0) / numeric.length
                    : [...values].sort(compareValues)[metric.operation === 'min' ? 0 : values.length - 1]!
          return [metric.alias, value]
        })
      )
    }))
  }
}
