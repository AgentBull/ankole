import { expectedVersions } from './records'
import type { BaseRecord, RecordData, RecordWrite, TableBinding, WriteResult } from './types'

/** Capture a resolved mapping together with the write adapter used by this render. */
export function boundTable(
  slot: string,
  binding: TableBinding | undefined,
  write: (changes: RecordWrite) => Promise<WriteResult>
) {
  const configured = binding?.status === 'ready' && !!binding.tableId
  const fields = binding?.fields ?? {}
  const field = (key: string) => {
    const id = fields[key]
    if (!configured || !id) throw new Error(`Unconfigured Applet binding: ${slot}.${key}`)
    return id
  }
  const requireTable = () => {
    if (!configured) throw new Error(`Unconfigured Applet binding: ${slot}`)
  }
  const patch = (values: RecordData): RecordData =>
    Object.fromEntries(Object.entries(values).map(([key, value]) => [field(key), value]))
  return {
    tableId: binding?.tableId ?? null,
    fields,
    status: binding?.status ?? 'missing_table',
    configured,
    field,
    read: (record: BaseRecord): RecordData =>
      Object.fromEntries(
        Object.entries(fields)
          .filter((entry): entry is [string, string] => !!entry[1] && Object.hasOwn(record.data, entry[1]))
          .map(([key, id]) => [key, record.data[id]])
      ),
    patch,
    create(values: RecordData | RecordData[]) {
      requireTable()
      return write({ creates: (Array.isArray(values) ? values : [values]).map(value => ({ data: patch(value) })) })
    },
    update(capturedRecord: BaseRecord, values: RecordData) {
      requireTable()
      const data = patch(values)
      return write({
        updates: [{ id: capturedRecord.id, data, expected_versions: expectedVersions(capturedRecord, data) }]
      })
    },
    remove(capturedRecord: BaseRecord) {
      requireTable()
      return write({ deletes: [{ id: capturedRecord.id, expected_versions: capturedRecord.versions }] })
    }
  }
}
