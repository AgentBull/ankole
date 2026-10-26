import { expect, test } from 'bun:test'
import { expectedVersions } from '../src/index'
import type { BaseRecord } from '../src/types'

test('a field update only expects written fields and retains absence for unwritten fields', () => {
  const record: BaseRecord = {
    id: 'record',
    data: { a: 1, b: 2 },
    versions: { a: 3, b: 4 },
    created_at: '',
    updated_at: '',
    created_by: '',
    updated_by: ''
  }
  expect(expectedVersions(record, { a: 5, never_written: 9 })).toEqual({ a: 3 })
  expect(record.versions).toEqual({ a: 3, b: 4 })
})
