// Tests for the minimal USTAR writer. They verify the produced bytes against the
// USTAR layout a real `tar` reader expects: header field offsets, the checksum
// convention, gzip round-trip, and rejection of names too long for USTAR.
import { describe, expect, it } from 'bun:test'
import { createTar, createTarGz } from './tar'

const NUL = String.fromCharCode(0)

// Reads a fixed-width header field, stopping at the first NUL (USTAR fields are
// NUL-padded, so the value is everything before the first NUL).
function field(block: Uint8Array, offset: number, len: number): string {
  const text = new TextDecoder().decode(block.subarray(offset, offset + len))
  return text.split(NUL)[0] ?? text
}

describe('tar', () => {
  it('writes a valid USTAR header and padded content', () => {
    const data = new TextEncoder().encode('hello')
    const tar = createTar([{ name: 'temp/hello.txt', data, mode: 0o644 }])

    expect(field(tar, 0, 100)).toBe('temp/hello.txt')
    expect(parseInt(field(tar, 124, 12), 8)).toBe(5) // size
    expect(field(tar, 257, 5)).toBe('ustar')
    expect(new TextDecoder().decode(tar.subarray(512, 517))).toBe('hello')

    // Checksum = sum of all bytes with the checksum field read as spaces.
    let sum = 0
    for (let i = 0; i < 512; i++) sum += i >= 148 && i < 156 ? 0x20 : tar[i]!
    expect(parseInt(field(tar, 148, 8), 8)).toBe(sum)
  })

  it('gzips to the same tar bytes', () => {
    const entry = { name: 'a.txt', data: new TextEncoder().encode('x') }
    const gz = createTarGz([entry])
    expect(gz[0]).toBe(0x1f)
    expect(gz[1]).toBe(0x8b)
    expect(Buffer.from(Bun.gunzipSync(new Uint8Array(gz)))).toEqual(Buffer.from(createTar([entry])))
  })

  it('rejects names that do not fit USTAR', () => {
    const longSegment = 'a'.repeat(120)
    expect(() => createTar([{ name: longSegment, data: new Uint8Array() }])).toThrow()
  })
})
