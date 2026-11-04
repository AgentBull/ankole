import { expect, test } from 'bun:test'
import { previewRecordList, withRecordIDs } from '../src/records'
import type { BaseRecord, RecordWrite } from '../src/types'

test('a failed request can retry the same create identities', () => {
  const changes: RecordWrite = { creates: [{ data: {} }, { id: 'caller-id', data: {} }, { data: {} }] }
  withRecordIDs(changes)
  const ids = changes.creates!.map(row => row.id)
  expect(ids[0]).toMatch(/^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/)
  expect(ids[1]).toBe('caller-id')
  expect(ids[2]).not.toBe(ids[0])
  withRecordIDs(changes)
  expect(changes.creates!.map(row => row.id)).toEqual(ids)
})

test('a record list keeps its identity until a pending write changes a row', () => {
  const records = [record('a', 'one'), record('b', 'two')]
  expect(previewRecordList(records, [])).toBe(records)
  expect(previewRecordList(records, [{ creates: [{ data: {} }] }])).toBe(records)
  const next = previewRecordList(records, [{ updates: [{ id: 'a', data: { name: 'edited' }, expected_versions: {} }] }])
  expect(next).not.toBe(records)
  expect(next[0]).not.toBe(records[0])
  expect(next[0]?.data.name).toBe('edited')
  expect(next[1]).toBe(records[1])
})

function record(id: string, name: string): BaseRecord {
  return {
    id,
    data: { name },
    versions: {},
    created_at: '2026-11-05T00:00:00Z',
    updated_at: '2026-11-05T00:00:00Z',
    created_by: 'owner',
    updated_by: 'owner'
  }
}
