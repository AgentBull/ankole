import { describe, expect, test } from 'bun:test'
import type { AggregateQuery, BaseField, BaseRecord, RecordQuery } from '@ankole/applet-sdk/types'
import cases from './table-query-cases.json'
import { aggregateLocalRecords, principalUID, queryLocalRecords } from './table-query'

const fields = cases.fields as BaseField[]
const records = cases.records as BaseRecord[]
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
  test('created_by and updated_by filters and groups match bare principal UIDs against ActorRef values', () => {
    const attributionFields: BaseField[] = [
      { id: 'name', name: 'Name', type: 'text', config: {}, version: 1, is_primary: true },
      { id: 'creator', name: 'Created by', type: 'created_by', config: {}, version: 1, is_primary: false },
      { id: 'updater', name: 'Updated by', type: 'updated_by', config: {}, version: 1, is_primary: false }
    ]
    const attributedRecords: BaseRecord[] = [
      {
        id: 'r1',
        data: { name: 'First' },
        versions: { name: 1 },
        created_at: '2026-10-18T00:00:00.000000Z',
        updated_at: '2026-10-18T00:00:00.000000Z',
        created_by: 'ankole:01950000-0000-7000-8000-000000000001:principal/u_alice',
        updated_by: 'ankole:01950000-0000-7000-8000-000000000001:principal/u_bob'
      },
      {
        id: 'r2',
        data: { name: 'Second' },
        versions: { name: 1 },
        created_at: '2026-10-18T00:00:00.000000Z',
        updated_at: '2026-10-18T00:00:00.000000Z',
        created_by: 'ankole:01950000-0000-7000-8000-000000000001:principal/u_charlie',
        updated_by: ''
      }
    ]
    expect(principalUID('ankole:01950000-0000-7000-8000-000000000001:principal/U_Alice')).toBe('u_alice')
    expect(principalUID('  U_Alice  ')).toBe('u_alice')
    expect(principalUID({ uid: 'U_Alice' })).toBe('u_alice')
    expect(principalUID('')).toBeNull()

    expect(
      queryLocalRecords(attributedRecords, attributionFields, {
        filter: { conjunction: 'and', conditions: [{ field_id: 'creator', operator: 'is', value: 'u_alice' }] }
      }).map(record => record.id)
    ).toEqual(['r1'])

    expect(
      queryLocalRecords(attributedRecords, attributionFields, {
        filter: {
          conjunction: 'and',
          conditions: [{ field_id: 'updater', operator: 'is', value: '  U_BOB  ' }]
        }
      }).map(record => record.id)
    ).toEqual(['r1'])

    expect(
      queryLocalRecords(attributedRecords, attributionFields, {
        filter: {
          conjunction: 'and',
          conditions: [
            {
              field_id: 'creator',
              operator: 'is',
              value: 'ankole:01950000-0000-7000-8000-000000000001:principal/u_charlie'
            }
          ]
        }
      }).map(record => record.id)
    ).toEqual(['r2'])

    expect(
      queryLocalRecords(attributedRecords, attributionFields, {
        group: { field_id: 'creator', value: 'u_alice' }
      }).map(record => record.id)
    ).toEqual(['r1'])
  })
})
