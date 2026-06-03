import { describe, expect, it } from 'bun:test'
import { bs58Hash, deriveKey, genericHash } from '../../../index.js'

describe('blake3', () => {
  it('should hash a string', () => {
    const str = '天地玄黄，宇宙洪荒'
    const hash = genericHash(str)
    expect(hash).toBe('87219a44dc37c85d5f9497854c1ad56056cd9ad3161817f7d8a901d3ce33209b')
    const b58Hash = bs58Hash(str)
    expect(b58Hash).toBe('A6VkwJ6YGizRowh5jikMMrs6b11JX1f3AU4gondGqDb8')
  })

  it('should support custom salt', () => {
    const hash = genericHash('天地玄黄，宇宙洪荒', deriveKey('日月盈昃', '0'))
    expect(hash).toBe('5f1c3e6c5f8312d26bd866438aa22f15257f5582153241a938ea507f41977e17')
  })
})
