import { expect, test } from 'bun:test'
import type { TableSchema } from '@ankole/applet-sdk/types'
import cases from './table-query-cases.json'
import { canAggregateLocally, canQueryLocally } from './local-query'

const schema = {
  fields: cases.fields,
  mode: 'local',
  local_query: { text_contains_ascii: true, jsonb_compare: true }
} as TableSchema
test('numeric predicates and totals retain PostgreSQL precision while unfiltered small tables remain local', () => {
  expect(canQueryLocally(schema, {})).toBe(true)
  for (const field_id of ['amount', 'total']) {
    expect(
      canQueryLocally(schema, {
        filter: { conjunction: 'and', conditions: [{ field_id, operator: 'is', value: 1 / 3 }] }
      })
    ).toBe(false)
    expect(canQueryLocally(schema, { sort: [{ field_id, direction: 'asc' }] })).toBe(false)
    expect(
      canAggregateLocally(schema, { group_by: [{ field_id }], metrics: [{ operation: 'count', alias: 'count' }] })
    ).toBe(false)
  }
  expect(canAggregateLocally(schema, { metrics: [{ operation: 'sum', field_id: 'amount', alias: 'total' }] })).toBe(
    false
  )
  expect(canAggregateLocally(schema, { metrics: [{ operation: 'count', alias: 'count' }] })).toBe(true)
})
test('locale-sensitive operations share the server owner unless the actual base proves compatibility', () => {
  const filter = {
    conjunction: 'and' as const,
    conditions: [{ field_id: 'name', operator: 'text_contains' as const, value: 'I' }]
  }
  expect(canQueryLocally(schema, { filter })).toBe(true)
  expect(
    canQueryLocally({ ...schema, local_query: { text_contains_ascii: false, jsonb_compare: false } }, { filter })
  ).toBe(false)
  expect(
    canQueryLocally(
      { ...schema, local_query: { text_contains_ascii: false, jsonb_compare: false } },
      { sort: [{ field_id: 'tags', direction: 'asc' }] }
    )
  ).toBe(false)
  expect(
    canQueryLocally({ ...schema, local_query: undefined }, { sort: [{ field_id: 'name', direction: 'asc' }] })
  ).toBe(true)
})

test('equivalent datetime spellings use PostgreSQL normalization while canonical microseconds stay local', () => {
  const dates = {
    ...schema,
    fields: [
      { id: 'date', name: 'Date', type: 'datetime', config: {}, version: 1, is_primary: false },
      { id: 'created', name: 'Created', type: 'created_at', config: {}, version: 1, is_primary: false },
      {
        id: 'formula-date',
        name: 'Formula',
        type: 'formula',
        config: { result_type: 'datetime' },
        version: 1,
        is_primary: false
      }
    ]
  } as TableSchema
  for (const field_id of ['date', 'created', 'formula-date']) {
    for (const value of ['2026-01-01T00:00:00Z', '2026-01-01T08:00:00+08:00', '2026-02-30T00:00:00.000000Z']) {
      expect(
        canQueryLocally(dates, { filter: { conjunction: 'and', conditions: [{ field_id, operator: 'is', value }] } })
      ).toBe(false)
      expect(canQueryLocally(dates, { group: { field_id, value_json: JSON.stringify(value) } })).toBe(false)
    }
    const value = '2026-01-01T00:00:00.123456Z'
    expect(
      canQueryLocally(dates, { filter: { conjunction: 'and', conditions: [{ field_id, operator: 'is', value }] } })
    ).toBe(true)
    expect(canQueryLocally(dates, { group: { field_id, value } })).toBe(true)
    expect(
      canQueryLocally(dates, { filter: { conjunction: 'and', conditions: [{ field_id, operator: 'is_empty' }] } })
    ).toBe(true)
  }
})
