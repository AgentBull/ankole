import { Buffer } from 'node:buffer'
import type { FingerprintMode, ListEntry } from './types'
import { runtimeFabricFileProtocol, type FileFrameSender } from '../../fabric/fabric'

export const chunkSize = 2 * 1024 * 1024
export const creditWindow = 4 * 1024 * 1024
export const zstdLevel = 3

export function isFileTransferFrame(frames: Buffer[]): boolean {
  return frames.length > 0 && frames[0].equals(runtimeFabricFileProtocol)
}

export function readU64Frame(frame: Buffer | undefined, label: string): number {
  if (!frame || frame.byteLength !== 8) {
    throw new Error(`${label} must be a u64 frame`)
  }

  const value = frame.readBigUInt64BE()
  if (value > BigInt(Number.MAX_SAFE_INTEGER)) {
    throw new Error(`${label} exceeds JavaScript safe integer range`)
  }
  return Number(value)
}

export function u64Frame(value: number): Buffer {
  if (!Number.isSafeInteger(value) || value < 0) {
    throw new Error(`invalid u64 value: ${value}`)
  }

  const frame = Buffer.alloc(8)
  frame.writeBigUInt64BE(BigInt(value))
  return frame
}

export function readBoolFrame(frame: Buffer | undefined, label: string): boolean {
  if (!frame || frame.byteLength !== 1 || (frame[0] !== 0 && frame[0] !== 1)) {
    throw new Error(`${label} must be a bool frame`)
  }
  return frame[0] === 1
}

export function boolFrame(value: boolean): Buffer {
  return Buffer.from([value ? 1 : 0])
}

export function requiredTextFrame(frame: Buffer | undefined, label: string): string {
  const text = textFrame(frame)
  if (!text) {
    throw new Error(`${label} frame is required`)
  }
  return text
}

export function textFrame(frame: Buffer | undefined): string | undefined {
  if (!frame) return undefined
  return frame.toString('utf8')
}

export function fingerprintMode(value: unknown): FingerprintMode {
  if (value === undefined || value === null || value === '') return 'xxh3_128'
  if (value === 'none' || value === 'xxh3_128') return value
  throw new Error(`unsupported fingerprint: ${String(value)}`)
}

export function encodeEntries(entries: ListEntry[]): Buffer {
  return Buffer.concat([u32Frame(entries.length), ...entries.flatMap(encodeEntry)])
}

export async function sendError(
  sender: FileFrameSender,
  transferID: string,
  code: string,
  message: string
): Promise<void> {
  await sendFrame(sender, ['ERROR', transferID, code, message])
}

export async function sendFrame(sender: FileFrameSender, parts: Array<string | Buffer>): Promise<void> {
  await sender([runtimeFabricFileProtocol, ...parts.map(part => (typeof part === 'string' ? Buffer.from(part) : part))])
}

function encodeEntry(entry: ListEntry): Buffer[] {
  return [
    sizedStringFrame(entry.relative_path),
    sizedStringFrame(entry.kind),
    u64Frame(entry.size),
    u64Frame(entry.modified_unix_ms)
  ]
}

function sizedStringFrame(value: string): Buffer {
  const bytes = Buffer.from(value)
  return Buffer.concat([u32Frame(bytes.byteLength), bytes])
}

function u32Frame(value: number): Buffer {
  if (!Number.isSafeInteger(value) || value < 0 || value > 0xffffffff) {
    throw new Error(`invalid u32 value: ${value}`)
  }

  const frame = Buffer.alloc(4)
  frame.writeUInt32BE(value)
  return frame
}
