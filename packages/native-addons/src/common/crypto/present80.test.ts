import { describe, expect, it } from 'bun:test'
import { deriveKey, intDecrypt, intEncrypt } from '../../../index.js'

const KEY = deriveKey('天地玄黄', '2')

describe('present80', () => {
  it('should encrypt and decrypt a number', () => {
    const intID = 10003791231
    const encrypted = intEncrypt(intID, KEY)
    const decrypted = intDecrypt(encrypted, KEY)
    expect(decrypted).toBe(intID)
    expect(encrypted).not.toBe(intID)
  })
})
