import { describe, expect, test } from 'bun:test'
import vectors from '../../kernel/test/vectors/uuid_url.json'
import { uuidExpand, uuidShorten } from './uuid-url'

describe('Kernel UUID URL vectors', () => {
  for (const { uuid, short } of vectors.valid) {
    test(uuid, () => {
      expect(uuidShorten(uuid)).toBe(short)
      expect(uuidExpand(short)).toBe(uuid)
    })
  }
  test('rejects noncanonical aliases and malformed values', () => {
    for (const value of vectors.invalid_short) expect(uuidExpand(value)).toBeUndefined()
    for (const value of vectors.invalid_uuid) expect(uuidShorten(value)).toBeUndefined()
  })
})
