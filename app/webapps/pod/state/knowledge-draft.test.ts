import { describe, expect, test } from 'bun:test'
import { KnowledgeDraftModel, parseMetadata } from './knowledge-draft'

describe('explicit knowledge property drafts', () => {
  test('preserves nested design tokens and accepts a metadata-only change', () => {
    const draft = new KnowledgeDraftModel()
    draft.begin({ colors: { primary: '#123456' }, tags: ['brand'] })
    expect(draft.dirty.value).toBe(false)
    draft.change(0, { source: "primary: '#abcdef'\naccent: null" })
    expect(draft.dirty.value).toBe(true)
    expect(draft.parsed.value.metadata).toEqual({ colors: { primary: '#abcdef', accent: null }, tags: ['brand'] })
  })
  test('preserves arbitrary business keys and rejects values JSONB cannot represent', () => {
    const draft = new KnowledgeDraftModel()
    draft.begin(parseMetadata('__proto__: a business property'))
    expect(Object.keys(draft.parsed.value.metadata!)).toEqual(['__proto__'])
    expect(draft.parsed.value.metadata?.__proto__).toBe('a business property')
    expect(() => parseMetadata('score: .inf')).toThrow()
    expect(() => parseMetadata('loop: &loop [*loop]')).toThrow()
  })
  test('invalid YAML and duplicate property names keep the draft unsavable', () => {
    const draft = new KnowledgeDraftModel()
    draft.begin({ summary: 'Before' })
    draft.change(0, { source: '[' })
    expect(draft.parsed.value.error).not.toBeNull()
    draft.replace({ summary: 'After' })
    draft.add()
    draft.change(1, { key: 'summary', source: 'Duplicate' })
    expect(draft.parsed.value.error).toContain('Duplicate')
    expect(() => parseMetadata('- not\n- a mapping')).toThrow()
  })
})
