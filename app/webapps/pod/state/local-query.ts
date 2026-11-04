import { effectiveFieldType } from '../base-field-types'
import { safeJsonParse } from '@agentbull/active-support'
import type { AggregateQuery, BaseField, RecordQuery, TableSchema } from '@ankole/applet-sdk/types'

const numeric = (field?: BaseField) => !!field && effectiveFieldType(field) === 'number'
const datetime = (field?: BaseField) => !!field && effectiveFieldType(field) === 'datetime'
const canonicalDatetime = (value: unknown) => {
  if (value === null) return true
  if (typeof value !== 'string' || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6}Z$/.test(value)) return false
  const date = new Date(value)
  return Number.isFinite(date.getTime()) && date.toISOString().slice(0, 23) === value.slice(0, 23)
}
const array = (field?: BaseField) => !!field && effectiveFieldType(field) === 'array'

/** PostgreSQL remains the owner where locale or numeric precision cannot survive a JSON Number. */
export function canQueryLocally(schema: TableSchema, query: RecordQuery): boolean {
  if (schema.mode !== 'local') return false
  const field = (id: string) => schema.fields.find(item => item.id === id)
  if (query.group) {
    const definition = field(query.group.field_id)
    if (numeric(definition)) return false
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
  return (
    (query.filter?.conditions ?? []).every(condition => {
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
      sort => !numeric(field(sort.field_id)) && (!array(field(sort.field_id)) || !!schema.local_query?.jsonb_compare)
    )
  )
}

export function canAggregateLocally(schema: TableSchema, query: AggregateQuery): boolean {
  if (!canQueryLocally(schema, query)) return false
  const field = (id?: string) => schema.fields.find(item => item.id === id)
  return (
    !(query.group_by ?? []).some(group => numeric(field(group.field_id))) &&
    query.metrics.every(metric => {
      if (metric.operation === 'count') return true
      if (metric.operation === 'sum' || metric.operation === 'avg') return false
      const definition = field(metric.field_id)
      const type = definition?.type === 'formula' ? definition.config.result_type : definition?.type
      return type === 'text' || type === 'datetime' || type === 'created_at' || type === 'updated_at'
    })
  )
}
