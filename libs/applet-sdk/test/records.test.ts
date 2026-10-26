import { expect, test } from 'bun:test'
import { withRecordIDs } from '../src/records'
import type { RecordWrite } from '../src/types'

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
