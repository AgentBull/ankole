import { describe, expect, it } from 'bun:test'
import { Buffer } from 'node:buffer'
import { siphash24 } from '../../../index.js'

const KEY = Buffer.from('abcdefghijklmnop')

describe('siphash24', () => {
  it('should hash "hello world" correctly', () => {
    const out = siphash24(Buffer.from('hello world'), KEY)
    expect(Buffer.from(out).toString('hex')).toBe('cc381e910d3720ce')
  })

  it('should handle big input', () => {
    const out = siphash24(Buffer.alloc(1024 * 1024), KEY)
    expect(Buffer.from(out).toString('hex')).toBe('ef0fca94174ee536')
  })

  it('should throw errors for invalid inputs', () => {
    expect(() => {
      siphash24(Buffer.from('hi'), Buffer.alloc(0))
    }).toThrow()
  })
})
