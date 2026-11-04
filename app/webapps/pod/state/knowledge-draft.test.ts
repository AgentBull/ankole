import { DocumentDraftModel } from './document-draft'
import { describe, expect, test } from 'bun:test'
import { KnowledgeDraftModel, parseMetadata, knowledgeSubmission, acknowledgeKnowledge } from './knowledge-draft'

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

test('knowledge save acknowledges the captured XML and properties without consuming newer edits', () => {
  const body = new DocumentDraftModel()
  const draft = new KnowledgeDraftModel()
  body.load('page', '<page/>', 3)
  draft.begin({ arbitrary: { page_id: 'target', extra: [null, true, 9] } })
  body.xml.value = '<page><p>Submitted</p></page>'
  const submitted = knowledgeSubmission(body, draft)
  body.xml.value = '<page><p>New input</p></page>'
  draft.change(0, { source: 'page_id: target\nextra: [null, false, 10]\nunknown: preserved' })
  acknowledgeKnowledge(body, draft, submitted, { xml: submitted.xml, metadata: submitted.metadata, revision: 4 })
  expect(body.xml.value).toContain('New input')
  expect(body.savedXML.value).toBe(submitted.xml)
  expect(body.revision.value).toBe(4)
  expect(draft.parsed.value.metadata).toEqual({
    arbitrary: { page_id: 'target', extra: [null, false, 10], unknown: 'preserved' }
  })
  expect(draft.editing.value).toBe(true)
  expect(draft.dirty.value).toBe(true)

  const latest = knowledgeSubmission(body, draft)
  acknowledgeKnowledge(body, draft, latest, { xml: latest.xml, metadata: latest.metadata, revision: 5 })
  expect(draft.editing.value).toBe(false)
  expect(body.hasUnsavedChanges.value).toBe(false)
})

test('a knowledge response from a cancelled editing session cannot settle its replacement', () => {
  const body = new DocumentDraftModel()
  const draft = new KnowledgeDraftModel()
  body.load('page', '<page/>', 1)
  draft.begin({ title: 'First' })
  const submitted = knowledgeSubmission(body, draft)
  draft.finish()
  draft.begin({ title: 'Second' })
  body.xml.value = '<page><p>Second session</p></page>'
  acknowledgeKnowledge(body, draft, submitted, { xml: '<page/>', metadata: submitted.metadata, revision: 2 })
  expect(body.xml.value).toContain('Second session')
  expect(body.revision.value).toBe(1)
  expect(draft.parsed.value.metadata).toEqual({ title: 'Second' })
  expect(draft.editing.value).toBe(true)
})

test('metadata key order does not keep a confirmed knowledge draft open', () => {
  const body = new DocumentDraftModel()
  const draft = new KnowledgeDraftModel()
  body.load('page', '<page/>', 1)
  draft.begin({ tokens: { foreground: 'black', background: 'white' } })
  const submitted = knowledgeSubmission(body, draft)
  draft.change(0, { source: 'background: white\nforeground: black' })
  expect(draft.dirty.value).toBe(false)
  acknowledgeKnowledge(body, draft, submitted, {
    xml: '<page/>',
    metadata: { tokens: { background: 'white', foreground: 'black' } },
    revision: 2
  })
  expect(draft.editing.value).toBe(false)
  expect(body.revision.value).toBe(2)
})

test('metadata treats React-like business keys as ordinary JSON properties', () => {
  const draft = new KnowledgeDraftModel()
  draft.begin({ payload: { $$typeof: 'business', _owner: { uid: 'alice' } } })
  draft.change(0, { source: '$$typeof: business\n_owner: {uid: bob}' })
  expect(draft.dirty.value).toBe(true)
})
