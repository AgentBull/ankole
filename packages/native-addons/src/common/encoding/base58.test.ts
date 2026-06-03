import { describe, expect, it } from 'bun:test'
import { Buffer } from 'node:buffer'
import { base58Decode, base58Encode } from '../../../index.js'

describe('base58', () => {
  it('should encode correctly', () => {
    const encoded = base58Encode('hello world')
    expect(encoded).toBe('StV1DL6CwTryKyV')
  })

  it('should encode and decode a string', () => {
    const str = '得之我幸，失之我命。hello🇨🇳'
    const encoded = base58Encode(str)
    const decoded = base58Decode(encoded)
    expect(Buffer.from(decoded).toString('utf-8')).toBe(str)
  })
})
