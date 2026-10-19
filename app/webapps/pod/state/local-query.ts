import type { AggregateQuery, DatabaseField, RecordQuery, TableSchema } from '@ankole/applet-sdk/types'

const numeric = (field?: DatabaseField) =>
  field?.type === 'number' ||
  field?.type === 'auto_number' ||
  (field?.type === 'formula' && field.config.result_type === 'number')
const datetime = (field?: DatabaseField) =>
  !!field &&
  (['datetime', 'created_at', 'updated_at'].includes(field.type) ||
    (field.type === 'formula' && field.config.result_type === 'datetime'))
const canonicalDatetime = (value: unknown) => {
  if (value === null) return true
  if (typeof value !== 'string' || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6}Z$/.test(value)) return false
  const date = new Date(value)
  return Number.isFinite(date.getTime()) && date.toISOString().slice(0, 23) === value.slice(0, 23)
}
const array = (field?: DatabaseField) =>
  !!field &&
  (['user', 'link', 'attachment'].includes(field.type) || (field.type === 'select' && !!field.config.multiple))

/** PostgreSQL remains the owner where locale or numeric precision cannot survive a JSON Number. */
export function canQueryLocally(schema: TableSchema, query: RecordQuery): boolean {
  if (schema.mode !== 'local') return false
  const field = (id: string) => schema.fields.find(item => item.id === id)
  if (query.group) {
    const definition = field(query.group.field_id)
    if (numeric(definition)) return false
    if (datetime(definition)) {
      let value = query.group.value_json === null ? null : (query.group.value ?? null)
      if (query.group.value_json !== undefined && query.group.value_json !== null) {
        try {
          value = JSON.parse(query.group.value_json)
        } catch {
          return false
        }
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
