import { describe, expect, it } from 'bun:test'
import { crc32, crc32Hex } from '../../../index.js'

describe('crc32', () => {
  it('should return the correct crc32 hash', () => {
    const str = 'TestCase😊'
    expect(crc32(str)).toBe(1198634863)
    expect(crc32Hex(str)).toBe('4771b76f')
  })
})
