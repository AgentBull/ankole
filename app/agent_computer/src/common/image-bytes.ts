import { Buffer } from 'node:buffer'

export function imageBytes(value: Uint8Array | BufferSource): Buffer
export function imageBytes(value: unknown): Buffer | undefined
export function imageBytes(value: unknown): Buffer | undefined {
  if (ArrayBuffer.isView(value)) return Buffer.from(value.buffer, value.byteOffset, value.byteLength)
  if (value instanceof ArrayBuffer) return Buffer.from(value)
  return undefined
}
