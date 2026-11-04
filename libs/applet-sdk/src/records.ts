import type { BaseRecord, RecordWrite } from './types'

/** Assign each create its UUIDv7 once, so a retried request keeps the same identity. */
export function withRecordIDs(changes: RecordWrite): RecordWrite {
  for (const row of changes.creates ?? []) {
    if (row.id) continue
    const bytes = crypto.getRandomValues(new Uint8Array(16))
    let time = Date.now()
    for (let index = 5; index >= 0; index--) {
      bytes[index] = time % 256
      time = Math.floor(time / 256)
    }
    bytes[6] = (bytes[6]! & 15) | 0x70
    bytes[8] = (bytes[8]! & 63) | 0x80
    const hex = Array.from(bytes, value => value.toString(16).padStart(2, '0')).join('')
    row.id = `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`
  }
  return changes
}

/** Keep the loaded record list while no write is changing it. */
export function previewRecordList(records: readonly BaseRecord[], pending: readonly RecordWrite[]): BaseRecord[] {
  if (pending.length === 0) return records as BaseRecord[]
  let changed = false
  const next = records.map(record => {
    let data = record.data
    for (const changes of pending) {
      const update = changes.updates?.find(item => item.id === record.id)
      if (!update) continue
      data = { ...data, ...update.data }
    }
    if (data === record.data) return record
    changed = true
    return { ...record, data }
  })
  return changed ? next : (records as BaseRecord[])
}
