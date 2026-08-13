import { describe, expect, test } from 'bun:test'
import { resourceID } from './console-route-loaders'

describe('console route identifiers', () => {
  test('uses the lower bound from the owning API', () => {
    expect(resourceID('999', 1)).toBe(999)
    expect(resourceID('999', 1000)).toBeUndefined()
    expect(resourceID('1000', 1000)).toBe(1000)
  })

  test('rejects values that are not positive safe decimal integers', () => {
    expect(resourceID('0', 1)).toBeUndefined()
    expect(resourceID('-1', 1)).toBeUndefined()
    expect(resourceID('1e3', 1)).toBeUndefined()
    expect(resourceID('9007199254740992', 1)).toBeUndefined()
  })
})
