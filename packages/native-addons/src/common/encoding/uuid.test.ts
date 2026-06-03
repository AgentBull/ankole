import { describe, expect, it } from 'bun:test'
import { genBase36UUID, genShortUUID, genUUID, shortUUIDExpand, UUIDShorten } from '../../../index.js'

describe('uuid', () => {
  it('should generate a uuid', () => {
    const uuid = genUUID()
    expect(uuid).toBeDefined()
  })

  it('should shorten a uuid', () => {
    const uuid = genUUID()
    const shortened = UUIDShorten(uuid)
    expect(shortened).toBeDefined()
  })

  it('should expand a shortened uuid', () => {
    const uuid = genUUID()
    const shortened = UUIDShorten(uuid)
    const expanded = shortUUIDExpand(shortened)
    expect(expanded).toBe(uuid)
  })

  it('should generate a short uuid', () => {
    const shortUUID = genShortUUID()
    expect(shortUUID).toBeDefined()
  })

  it('should generate a base36 uuid', () => {
    const base36UUID = genBase36UUID()
    expect(base36UUID).toBeDefined()
  })
})
