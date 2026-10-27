import { describe, expect, test } from 'bun:test'
import type { BrainObjectPage } from './brain-object-editor-model'
import markdocCases from '../../../kernel/test/fixtures/brain_markdoc.json'
import {
  BrainObjectEditorModel,
  brainObjectSnapshot,
  emptyBrainObjectSnapshot,
  parseBrainObjectMeta,
  previewBrainObjectBody
} from './brain-object-editor-model'

describe('previewBrainObjectBody', () => {
  for (const fixture of markdocCases) {
    test(fixture.name, () => {
      const result = previewBrainObjectBody(fixture.source)
      if (fixture.error) {
        expect(result.segments).toEqual([])
        expect(String(result.error?.code)).toBe(fixture.error.code)
        expect(result.error?.line).toBe(fixture.error.line)
      } else {
        expect(result).toEqual({ segments: fixture.segments })
      }
    })
  }

  test('invalid bodies have no scope preview', () => {
    const model = new BrainObjectEditorModel()
    model.body.value = 'See {% audience scope="principal:alice" %}\nprivate\n{% /audience %}'
    expect(model.preview.value).toEqual([])
    expect(model.previewError.value).toEqual({ code: 'misplaced_audience_tag', line: 1 })
    model[Symbol.dispose]()
  })
})

describe('BrainObjectEditorModel', () => {
  test('validates metadata and builds create and update bodies', () => {
    const model = new BrainObjectEditorModel()
    model.initialize('new', emptyBrainObjectSnapshot())
    expect(model.draftError('new')).toBe('slug_required')

    model.slug.value = 'notes/one'
    model.title.value = 'One'
    model.body.value = 'Body'
    model.tags.value = [' research ', 'AI', 'research', '']
    model.metaText.value = '{"source":"console"}'
    model.effectiveDate.value = '2026-08-30'
    expect(model.draftError('new')).toBeUndefined()
    expect(model.createBody()).toMatchObject({
      slug: 'notes/one',
      type: 'note',
      body: 'Body',
      tags: ['research', 'AI'],
      meta: { source: 'console' },
      effective_date: '2026-08-30'
    })

    model.contentHash.value = 'hash-1'
    expect(model.updateBody().expected_content_hash).toBe('hash-1')
    model.tags.value = []
    expect(model.updateBody().tags).toEqual([])
    expect(model.dirty.value).toBeTrue()
    model[Symbol.dispose]()
  })

  test('preserves each tag through loading, unrelated edits, and tag edits', () => {
    const model = new BrainObjectEditorModel()
    const originalTags = ['alpha\nbeta', 'literal\\ntext', 'one\rtwo', 'one\r\ntwo']
    const page: BrainObjectPage = {
      slug: 'notes/tags',
      type: 'note',
      title: 'Tags',
      body: 'Body',
      meta: {},
      tags: originalTags,
      content_hash: 'hash-1',
      editable: true,
      contradictions: [],
      deleted: false,
      facts: [],
      rendered: 'Body',
      takes: [],
      links: { outgoing: [], incoming: [] },
      timelines: [],
      subtype: null,
      effective_date: null,
      edit_block_reason: null
    }
    model.initialize('object:notes/tags', brainObjectSnapshot(page))
    expect(model.dirty.value).toBeFalse()
    expect(model.updateBody().tags).toEqual(originalTags)

    model.title.value = 'Renamed'
    expect(model.updateBody().tags).toEqual(originalTags)
    model.updateTag(1, 'renamed\\ntext')
    expect(model.updateBody().tags).toEqual(['alpha\nbeta', 'renamed\\ntext', 'one\rtwo', 'one\r\ntwo'])
    expect(originalTags[1]).toBe('literal\\ntext')

    model.addTag()
    model.updateTag(4, 'new\nmultiline')
    model.removeTag(1)
    expect(model.updateBody().tags).toEqual(['alpha\nbeta', 'one\rtwo', 'one\r\ntwo', 'new\nmultiline'])
    model.markSaved(page)
    expect(model.tags.value).toEqual(originalTags)
    expect(model.dirty.value).toBeFalse()
    model.reset()
    expect(model.tags.value).toEqual([])
    model[Symbol.dispose]()
  })

  test('keeps a draft when the same object refetches', () => {
    const model = new BrainObjectEditorModel()
    const initial = { ...emptyBrainObjectSnapshot(), slug: 'notes/one', title: 'One', contentHash: 'hash-1' }
    model.initialize('object:notes/one', initial)
    model.body.value = 'Local draft'

    model.initialize('object:notes/one', { ...initial, body: 'Remote body', contentHash: 'hash-2' })

    expect(model.body.value).toBe('Local draft')
    expect(model.contentHash.value).toBe('hash-1')
    model[Symbol.dispose]()
  })

  test('advances the CAS hash for an explicit conflict comparison without replacing the draft', () => {
    const model = new BrainObjectEditorModel()
    const initial = { ...emptyBrainObjectSnapshot(), slug: 'notes/one', body: 'Original', contentHash: 'hash-1' }
    model.initialize('object:notes/one', initial)
    model.body.value = 'Local draft'

    model.useLatestContentHash('hash-2')

    expect(model.body.value).toBe('Local draft')
    expect(model.contentHash.value).toBe('hash-2')
    expect(model.updateBody().expected_content_hash).toBe('hash-2')
    model[Symbol.dispose]()
  })

  test('auto-derives slug from title until slug is manually edited', () => {
    const model = new BrainObjectEditorModel()
    model.initialize('new', emptyBrainObjectSnapshot())

    model.setTitle('Quarterly Review 2026', true)
    expect(model.slug.value).toBe('quarterly-review-2026')

    model.setSlug('notes/q1-review')
    model.setTitle('Updated Review Title', true)
    expect(model.slug.value).toBe('notes/q1-review')
    model[Symbol.dispose]()
  })
})

test('parseBrainObjectMeta accepts only JSON objects', () => {
  expect(parseBrainObjectMeta('{"a":1}')).toEqual({ a: 1 })
  expect(parseBrainObjectMeta('[]')).toBeUndefined()
  expect(parseBrainObjectMeta('null')).toBeUndefined()
  expect(parseBrainObjectMeta('{')).toBeUndefined()
})
