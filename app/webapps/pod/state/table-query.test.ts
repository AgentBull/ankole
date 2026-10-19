import { describe, expect, test } from 'bun:test'
import type { AggregateQuery, DatabaseField, DatabaseRecord, RecordQuery } from '@ankole/applet-sdk/types'
import cases from './table-query-cases.json'
import { aggregateLocalRecords, queryLocalRecords } from './table-query'

const fields = cases.fields as DatabaseField[]
const records = cases.records as DatabaseRecord[]
describe('shared SQL and local table query contract', () => {
  for (const fixture of cases.queries) {
    test(fixture.name, () => {
      expect(queryLocalRecords(records, fields, fixture.query as RecordQuery).map(record => record.id)).toEqual(
        fixture.ids
      )
    })
  }
  for (const fixture of cases.aggregates) {
    test(fixture.name, () => {
      expect(aggregateLocalRecords(records, fields, fixture.query as AggregateQuery, 1).groups).toEqual(fixture.groups)
    })
  }
  test('multi-value grouping counts a row in each group and uses only numeric values', () => {
    const result = aggregateLocalRecords(
      records,
      fields,
      {
        group_by: [{ field_id: 'tags' }],
        metrics: [
          { operation: 'count', alias: 'count' },
          { operation: 'sum', field_id: 'amount', alias: 'sum' }
        ]
      },
      9
    )
    expect(result).toEqual({
      data_version: 9,
      groups: [
        { values: ['red'], metrics: { count: 2, sum: 4 } },
        { values: ['blue'], metrics: { count: 1, sum: 2 } },
        { values: [null], metrics: { count: 2, sum: 5 } }
      ]
    })
  })
  test('group paging adds its condition outside an OR filter', () => {
    expect(
      queryLocalRecords(records, fields, {
        filter: {
          conjunction: 'or',
          conditions: [
            { field_id: 'name', operator: 'is', value: 'Alpha' },
            { field_id: 'name', operator: 'is', value: 'beta' }
          ]
        },
        group: { field_id: 'tags', value_json: '"blue"' }
      }).map(record => record.id)
    ).toEqual(['a'])
  })
})
