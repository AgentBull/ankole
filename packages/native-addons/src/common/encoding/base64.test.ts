import { describe, expect, it } from 'bun:test'
import { Buffer } from 'node:buffer'
import { base64UrlSafeDecode, base64UrlSafeEncode } from '../../../index.js'

describe('base64', () => {
  it('should encode correctly', () => {
    const encoded = base64UrlSafeEncode('https://google.com')
    expect(encoded).toBe('aHR0cHM6Ly9nb29nbGUuY29t')
  })

  it('should encode and decode a string', () => {
    const str = '🇨🇳2024 致良知'
    const encoded = base64UrlSafeEncode(str)
    const decoded = base64UrlSafeDecode(encoded)
    expect(Buffer.from(decoded).toString('utf-8')).toBe(str)
  })
})
