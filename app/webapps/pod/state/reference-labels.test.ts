import { expect, spyOn, test } from 'bun:test'
import type { BaseRecord, TableSchema } from '@ankole/applet-sdk/types'
import { loadReferenceLabels } from '../base-field-value'
import { baseHTTP } from '../base-api'

const record = (id: string): BaseRecord => ({
  id,
  data: { name: `Label ${id}` },
  versions: { name: 1 },
  created_at: '2026-10-18T00:00:00.000000Z',
  updated_at: '2026-10-18T00:00:00.000000Z',
  created_by: 'person',
  updated_by: 'person'
})

test('reference labels retain 1000-ID batches and follow response pages smaller than each batch', async () => {
  const ids = Array.from({ length: 1001 }, (_, index) => String(index))
  const definition: TableSchema = {
    table: { id: 'target', page_id: 'page', name: 'Target', data_version: 1, record_count: ids.length },
    fields: [{ id: 'name', name: 'Name', type: 'text', config: {}, version: 1, is_primary: true }],
    views: [],
    mode: 'local'
  }
  const schema = spyOn(baseHTTP, 'schema').mockResolvedValue(definition)
  const query = spyOn(baseHTTP, 'query').mockImplementation(async (_tableID, query) => {
    const batch = query.ids!
    const offset = Number(query.page_token ?? 0)
    const next = offset + 2 < batch.length ? String(offset + 2) : null
    return {
      records: batch.slice(offset, offset + 2).map(record),
      data_version: 1,
      complete: !next,
      page_token: next
    }
  })
  try {
    const labels = await loadReferenceLabels('target', ids)
    expect(labels.size).toBe(ids.length)
    expect(labels.get('1000')).toBe('Label 1000')
    const batches = query.mock.calls.filter(([, query]) => !query.page_token).map(([, query]) => query.ids)
    expect(batches.map(batch => batch!.length)).toEqual([1000, 1])
    expect(query).toHaveBeenCalledTimes(501)
    expect(schema).toHaveBeenCalledTimes(1)
  } finally {
    schema.mockRestore()
    query.mockRestore()
  }
})
