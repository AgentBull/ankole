import type { RecordWrite } from './types'

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
