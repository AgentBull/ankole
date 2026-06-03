import { describe, expect, it } from 'bun:test'
import { Buffer } from 'node:buffer'
import { aeadDecrypt, aeadEncrypt, deriveKey } from '../../../index.js'

const plain = '穿越长城，走向世界。Across the Great Wall we can reach every corner in the world.'
const key = deriveKey('mock-key', '1024')

describe('xchacha20_poly1305', () => {
  it('should encrypt and decrypt a string', () => {
    const cipher = aeadEncrypt(plain, key)
    const decrypted = aeadDecrypt(cipher, key)
    expect(Buffer.from(decrypted).toString('utf-8')).toBe(plain)
  })
})
