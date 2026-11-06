import { effectiveFieldType } from '../base-field-types'
import { safeJsonParse } from '@agentbull/active-support'
import type { AggregateQuery, BaseField, RecordQuery, TableSchema } from '@ankole/applet-sdk/types'

const RECORD_QUERY_KEYS = new Set(['filter', 'sort', 'page_size', 'page_token', 'ids', 'group'])
const RECORD_GROUP_KEYS = new Set(['field_id', 'value', 'value_json'])
const FILTER_KEYS = new Set(['conjunction', 'conditions'])
const CONDITION_KEYS = new Set(['field_id', 'operator', 'value'])
const CONDITION_OPERATORS = new Set([
  'is',
  'contains',
  'is_empty',
  'is_not_empty',
  'gt',
  'gte',
  'lt',
  'lte',
  'text_contains'
])
const SORT_KEYS = new Set(['field_id', 'direction'])
const AGGREGATE_QUERY_KEYS = new Set(['filter', 'group_by', 'metrics'])
const GROUP_BY_KEYS = new Set(['field_id', 'bucket'])
const BUCKET_UNITS = new Set(['day', 'week', 'month', 'quarter', 'year'])
const METRIC_KEYS = new Set(['operation', 'field_id', 'alias'])

function hasOnlyAllowedKeys(record: object, allowed: ReadonlySet<string>): boolean {
  return Object.entries(record).every(([key, value]) => value === undefined || allowed.has(key))
}

const numeric = (field?: BaseField) => !!field && effectiveFieldType(field) === 'number'
const datetime = (field?: BaseField) => !!field && effectiveFieldType(field) === 'datetime'
const canonicalDatetime = (value: unknown) => {
  if (value === null) return true
  if (typeof value !== 'string' || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6}Z$/.test(value)) return false
  const date = new Date(value)
  return Number.isFinite(date.getTime()) && date.toISOString().slice(0, 23) === value.slice(0, 23)
}
const array = (field?: BaseField) => !!field && effectiveFieldType(field) === 'array'

/** PostgreSQL remains the owner where locale, precision, or advanced slice/ranking clauses apply. */
export function canQueryLocally(schema: TableSchema, query: RecordQuery): boolean {
  if (schema.mode !== 'local') return false
  if (!hasOnlyAllowedKeys(query, RECORD_QUERY_KEYS)) return false
  const field = (id: string) => schema.fields.find(item => item.id === id)
  if (query.group) {
    if (Array.isArray(query.group) || !hasOnlyAllowedKeys(query.group, RECORD_GROUP_KEYS)) return false
    const definition = field(query.group.field_id)
    if (!definition || numeric(definition)) return false
    if (datetime(definition)) {
      let value: unknown = query.group.value_json === null ? null : (query.group.value ?? null)
      if (query.group.value_json !== undefined && query.group.value_json !== null) {
        const parsed = safeJsonParse(query.group.value_json)
        if (parsed.isErr()) return false
        value = parsed.value
      }
      if (!canonicalDatetime(value)) return false
    }
  }
  if (query.filter && !hasOnlyAllowedKeys(query.filter, FILTER_KEYS)) return false
  return (
    (query.filter?.conditions ?? []).every(condition => {
      if (!hasOnlyAllowedKeys(condition, CONDITION_KEYS) || !CONDITION_OPERATORS.has(condition.operator)) return false
      const definition = field(condition.field_id)
      if (['is_empty', 'is_not_empty'].includes(condition.operator)) return true
      if (numeric(definition)) return false
      if (datetime(definition) && !canonicalDatetime(condition.value)) return false
      if (condition.operator === 'text_contains') return !!schema.local_query?.text_contains_ascii
      return (
        !array(definition) ||
        !['gt', 'gte', 'lt', 'lte'].includes(condition.operator) ||
        !!schema.local_query?.jsonb_compare
      )
    }) &&
    (query.sort ?? []).every(
      sort =>
        hasOnlyAllowedKeys(sort, SORT_KEYS) &&
        (sort.direction === 'asc' || sort.direction === 'desc') &&
        !numeric(field(sort.field_id)) &&
        (!array(field(sort.field_id)) || !!schema.local_query?.jsonb_compare)
    )
  )
}

export function canAggregateLocally(schema: TableSchema, query: AggregateQuery): boolean {
  if (!hasOnlyAllowedKeys(query, AGGREGATE_QUERY_KEYS)) return false
  if (!canQueryLocally(schema, query.filter ? { filter: query.filter } : {})) return false
  const field = (id?: string) => schema.fields.find(item => item.id === id)
  return (
    (query.group_by ?? []).every(
      group =>
        hasOnlyAllowedKeys(group, GROUP_BY_KEYS) &&
        (group.bucket === undefined || BUCKET_UNITS.has(group.bucket)) &&
        !numeric(field(group.field_id))
    ) &&
    query.metrics.every(metric => {
      if (!hasOnlyAllowedKeys(metric, METRIC_KEYS)) return false
      if (metric.operation === 'count') return true
      if (metric.operation !== 'min' && metric.operation !== 'max') return false
      const definition = field(metric.field_id)
      const type = definition?.type === 'formula' ? definition.config.result_type : definition?.type
      return type === 'text' || type === 'datetime' || type === 'created_at' || type === 'updated_at'
    })
  )
}
