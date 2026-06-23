import { describe, expect, it } from 'bun:test'
import { Buffer } from 'node:buffer'
import * as kernel from '../index.js'

const aeadKey = '000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f'
const aeadCiphertext = 'vveE4WxRjp0KO8YVx7o09aQ5_q9ZzqX2.gb1S9PmqEp_5UuejAzvKErXrdE4-sQ'

describe('@ankole/kernel', () => {
  it('exports the public Bun API', () => {
    for (const name of [
      'aeadDecrypt',
      'aeadEncrypt',
      'authzAuthorize',
      'authzAuthorizeAll',
      'authzMatchResourcePattern',
      'authzValidateCondition',
      'authzValidateResourcePattern',
      'anyAscii',
      'base58Decode',
      'base58Encode',
      'base64UrlSafeDecode',
      'base64UrlSafeEncode',
      'bs58Hash',
      'crc32',
      'crc32Hex',
      'deriveKey',
      'genBase36UUID',
      'generateKey',
      'genericHash',
      'phoneNormalizeE164',
      'genShortUUID',
      'genUUID',
      'genUUIDv7',
    ]) {
      expect(kernel[name as keyof typeof kernel]).toBeFunction()
    }
  })

  it('generates TypeScript declarations during build', async () => {
    expect(await Bun.file(new URL('../index.d.ts', import.meta.url)).exists()).toBe(true)
  })

  it('hashes and derives keys with shared BLAKE3 vectors', () => {
    expect(kernel.genericHash('bullx')).toBe('7f31cabae40697f9404428671c582d3c1f80c8a13d0741f4be8c9b856fcc0706')
    expect(kernel.bs58Hash(Buffer.from('bullx'))).toBe('9ZWpCkNYVXH91wFYb4cygXBxLe2xwsK9rBTVxwPMicWZ')
    expect(kernel.deriveKey('seed', 'tenant-A', 'scope-a')).toBe(
      '0553f445a2fb3dfc0fab4efa1e1ed31ef6a103277286cf63874904e341ee0d20',
    )
  })

  it('encrypts and decrypts AEAD payloads', () => {
    const encrypted = kernel.aeadEncrypt(Buffer.from('secret'), aeadKey)

    expect(encrypted.split('.')).toHaveLength(2)
    expect(encrypted).not.toContain('=')
    expect(Buffer.from(kernel.aeadDecrypt(encrypted, aeadKey)).toString('utf8')).toBe('secret')
    expect(Buffer.from(kernel.aeadDecrypt(aeadCiphertext, aeadKey)).toString('utf8')).toBe('secret')
  })

  it('encodes and decodes base58 and base64url payloads', () => {
    expect(kernel.base58Encode('Hello World!')).toBe('2NEpo7TZRRrLZSi2U')
    expect(Buffer.from(kernel.base58Decode('2NEpo7TZRRrLZSi2U')).toString('utf8')).toBe('Hello World!')

    expect(kernel.base64UrlSafeEncode(Buffer.from('bullx'))).toBe('YnVsbHg')
    expect(Buffer.from(kernel.base64UrlSafeDecode('YnVsbHg')).toString('utf8')).toBe('bullx')
  })

  it('authorizes direct grants with the shared AuthZ engine', () => {
    expect(kernel.authzValidateCondition('principal.type == "human"')).toBe(true)
    expect(kernel.authzValidateResourcePattern('workspace:**')).toBe(true)
    expect(kernel.authzMatchResourcePattern('workspace:**', 'workspace:default')).toBe(true)

    const decision = kernel.authzAuthorize({
      principal: {
        uid: 'alice',
        type: 'human',
        status: 'active',
      },
      staticGroupIds: [],
      computedGroups: [],
      grants: [
        {
          id: 'grant-1',
          principalUid: 'alice',
          resourcePattern: 'workspace:**',
          action: 'read',
          condition: 'context.request.source == "test"',
        },
      ],
      resource: 'workspace:default',
      action: 'read',
      context: { source: 'test' },
    })

    expect(decision).toMatchObject({
      status: 'allow',
      diagnostics: [],
      effectiveGroupIds: [],
    })
  })

  it('supports text normalization and crc32 helpers', () => {
    expect(kernel.anyAscii('Björk')).toBe('Bjork')
    expect(kernel.crc32('TestCase😊')).toBe(1198634863)
    expect(kernel.crc32Hex(Buffer.from('TestCase😊'))).toBe('4771b76f')
    expect(kernel.phoneNormalizeE164('+1 415 555 2671')).toBe('+14155552671')
    expect(() => kernel.phoneNormalizeE164('13800000000')).toThrow()
  })

  it('generates uuid variants in the expected formats', () => {
    expect(kernel.generateKey()).toMatch(/^[0-9a-f]{64}$/)
    expect(kernel.genUUID()).toMatch(/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/)
    expect(kernel.genUUIDv7()).toMatch(/^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/)
    expect(kernel.genBase36UUID()).toMatch(/^[0-9a-z]+$/)
    expect(kernel.genShortUUID()).toMatch(/^[1-9A-HJ-NP-Za-km-z]+$/)
  })
})
