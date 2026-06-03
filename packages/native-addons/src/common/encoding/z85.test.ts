import { describe, expect, it } from 'bun:test'
import { Buffer } from 'node:buffer'
import { z85Decode, z85Encode } from '../../../index.js'

describe('z85', () => {
  it('should encode and decode a string', () => {
    const str = '🇨🇳天地玄黄，宇宙洪荒🇨🇳'
    const encoded = z85Encode(str)
    const decoded = z85Decode(encoded)
    expect(Buffer.from(decoded).toString('utf-8')).toBe(str)
  })

  it('should encode correctly', () => {
    const encoded = z85Encode('https://agentbull.cn')
    expect(encoded).toBe('xMOunB2>%cvp%d?ByGxey+xjn')
  })
})
