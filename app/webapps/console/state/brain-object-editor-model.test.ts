import { describe, expect, test } from 'bun:test'
import {
  BrainObjectEditorModel,
  emptyBrainObjectSnapshot,
  parseBrainObjectMeta,
  previewBrainObjectBody
} from './brain-object-editor-model'

describe('previewBrainObjectBody', () => {
  test('splits root audience blocks and keeps document order', () => {
    const body = [
      '# Public',
      '{% audience scope="principal:alice" %}',
      'Private',
      '{% /audience %}',
      'Public tail'
    ].join('\n')

    expect(previewBrainObjectBody(body)).toEqual([
      { scope: 'world', text: '# Public\n' },
      { scope: 'principal:alice', text: 'Private\n' },
      { scope: 'world', text: 'Public tail' }
    ])
  })

  test('does not treat a tag line inside a fence as a scope boundary', () => {
    const body = [
      '{% audience scope="principal:alice" %}',
      'Private',
      '~~~markdoc',
      '{% /audience %}',
      '~~~',
      'Still private',
      '{% /audience %}'
    ].join('\n')

    expect(previewBrainObjectBody(body)).toEqual([
      {
        scope: 'principal:alice',
        text: ['Private', '~~~markdoc', '{% /audience %}', '~~~', 'Still private'].join('\n') + '\n'
      }
    ])
  })

  test('shows wikilinks as literal Markdown text', () => {
    expect(previewBrainObjectBody('See [[companies/acme]].')).toEqual([
      { scope: 'world', text: 'See [[companies/acme]].' }
    ])
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
    model.metaText.value = '{"source":"console"}'
    model.effectiveDate.value = '2026-08-30'
    expect(model.draftError('new')).toBeUndefined()
    expect(model.createBody()).toMatchObject({
      slug: 'notes/one',
      type: 'note',
      body: 'Body',
      meta: { source: 'console' },
      effective_date: '2026-08-30'
    })

    model.contentHash.value = 'hash-1'
    expect(model.updateBody().expected_content_hash).toBe('hash-1')
    expect(model.dirty.value).toBeTrue()
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
})

test('parseBrainObjectMeta accepts only JSON objects', () => {
  expect(parseBrainObjectMeta('{"a":1}')).toEqual({ a: 1 })
  expect(parseBrainObjectMeta('[]')).toBeUndefined()
  expect(parseBrainObjectMeta('null')).toBeUndefined()
  expect(parseBrainObjectMeta('{')).toBeUndefined()
})
