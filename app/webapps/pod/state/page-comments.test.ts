import { expect, test } from 'bun:test'
import { PageCommentsModel } from './page-comments'

test('a completed comment request cannot consume text typed while it was in flight', () => {
  const model = new PageCommentsModel('comment-pending')
  const anchor = { quote: 'A paragraph', read: () => ({ from: 1, to: 12, quote: 'A paragraph' }) }
  model.capture(anchor)
  model.write('new', 'First request')
  model.write('new', 'Next request')
  model.sent('new', 'First request', anchor)
  expect(model.drafts.value.new).toBe('Next request')
  expect(model.anchor.value).toBe(anchor)
  model.sent('new', 'Next request', anchor)
  expect(model.drafts.value.new).toBeUndefined()
  expect(model.anchor.value).toBeNull()
  model[Symbol.dispose]()
})

test('reply and edit drafts belong to their own thread or comment', () => {
  const model = new PageCommentsModel('comment-scope')
  model.write('reply:one', 'Reply')
  model.write('edit:two', 'Edit')
  model.sent('reply:one', 'Reply')
  expect(model.drafts.value['reply:one']).toBeUndefined()
  expect(model.drafts.value['edit:two']).toBe('Edit')
  model[Symbol.dispose]()
})

test('a completed comment request cannot consume the same text attached to a newer selection', () => {
  const model = new PageCommentsModel('comment-anchor-pending')
  const first = { quote: 'First paragraph', read: () => ({ from: 1, to: 16, quote: 'First paragraph' }) }
  const next = { quote: 'Second paragraph', read: () => ({ from: 20, to: 36, quote: 'Second paragraph' }) }
  model.capture(first)
  model.write('new', 'Please clarify')
  model.capture(next)
  model.sent('new', 'Please clarify', first)
  expect(model.drafts.value.new).toBe('Please clarify')
  expect(model.anchor.value).toBe(next)
  model.sent('new', 'Please clarify', next)
  expect(model.drafts.value.new).toBeUndefined()
  expect(model.anchor.value).toBeNull()
  model[Symbol.dispose]()
})

test('an edit draft keeps its starting version across another tab update and reopening until explicitly reviewed', () => {
  const model = new PageCommentsModel('comment-edit-version')
  model.beginEdit('edit:one', 'Original', 1)
  model.write('edit:one', 'My draft')
  // A refreshed query and reopening the composer must not silently authorize overwriting version 2.
  model.beginEdit('edit:one', 'Saved in another tab', 2)
  expect(model.editVersions.value['edit:one']).toBe(1)
  expect(model.drafts.value['edit:one']).toBe('My draft')
  model.reviewEdit('edit:one', 2)
  expect(model.editVersions.value['edit:one']).toBe(2)
  expect(model.drafts.value['edit:one']).toBe('My draft')
  expect(model.edited('edit:one', 'My draft', 2, 3)).toBe(true)
  expect(model.editVersions.value['edit:one']).toBeUndefined()
  expect(model.drafts.value['edit:one']).toBeUndefined()
  model.beginEdit('edit:one', 'Latest saved text', 3)
  expect(model.drafts.value['edit:one']).toBe('Latest saved text')
  expect(model.editVersions.value['edit:one']).toBe(3)
  model[Symbol.dispose]()
})

test('a completed edit preserves text typed in flight and advances its base to the successful save', () => {
  const model = new PageCommentsModel('comment-edit-pending')
  model.beginEdit('edit:one', 'Original', 1)
  model.write('edit:one', 'Submitted')
  model.write('edit:one', 'Continued typing')
  expect(model.edited('edit:one', 'Submitted', 1, 2)).toBe(false)
  expect(model.drafts.value['edit:one']).toBe('Continued typing')
  expect(model.editVersions.value['edit:one']).toBe(2)
  expect(model.edited('edit:one', 'Continued typing', 2, 3)).toBe(true)
  expect(model.drafts.value['edit:one']).toBeUndefined()
  model[Symbol.dispose]()
})

test('an older edit response cannot consume or downgrade an explicitly reviewed newer draft', () => {
  const model = new PageCommentsModel('comment-edit-reviewed')
  model.beginEdit('edit:one', 'My draft', 1)
  model.reviewEdit('edit:one', 3)
  expect(model.edited('edit:one', 'My draft', 1, 2)).toBe(false)
  expect(model.drafts.value['edit:one']).toBe('My draft')
  expect(model.editVersions.value['edit:one']).toBe(3)
  model[Symbol.dispose]()
})

test('persisted edit drafts retain their starting version and empty text after reload', () => {
  const descriptor = Object.getOwnPropertyDescriptor(globalThis, 'localStorage')
  const storage = new Map<string, string>()
  Object.defineProperty(globalThis, 'localStorage', {
    configurable: true,
    value: {
      getItem: (key: string) => storage.get(key) ?? null,
      setItem: (key: string, value: string) => storage.set(key, value),
      removeItem: (key: string) => storage.delete(key)
    }
  })
  try {
    const first = new PageCommentsModel('persisted-comment')
    first.beginEdit('edit:one', 'Original', 1)
    first.write('edit:one', '')
    first[Symbol.dispose]()
    const reopened = new PageCommentsModel('persisted-comment')
    reopened.beginEdit('edit:one', 'Another tab saved this', 2)
    expect(reopened.drafts.value['edit:one']).toBe('')
    expect(reopened.editVersions.value['edit:one']).toBe(1)
    reopened.reviewEdit('edit:one', 2)
    reopened[Symbol.dispose]()
    const reviewed = new PageCommentsModel('persisted-comment')
    expect(reviewed.drafts.value['edit:one']).toBe('')
    expect(reviewed.editVersions.value['edit:one']).toBe(2)
    reviewed[Symbol.dispose]()

    storage.set('unversioned-comment', JSON.stringify({ drafts: { 'edit:one': 'Recovered draft' } }))
    const unversioned = new PageCommentsModel('unversioned-comment')
    unversioned.beginEdit('edit:one', 'Current body', 7)
    expect(unversioned.drafts.value['edit:one']).toBe('Recovered draft')
    expect(unversioned.editVersions.value['edit:one']).toBeUndefined()
    unversioned.reviewEdit('edit:one', 7)
    expect(unversioned.editVersions.value['edit:one']).toBe(7)
    unversioned[Symbol.dispose]()

    const transient = new PageCommentsModel('transient-comment')
    transient.capture({
      quote: 'Confidential excerpt',
      read: () => ({ from: 1, to: 10, quote: 'Confidential excerpt' })
    })
    transient.write('new', 'Draft note')
    expect(storage.has('transient-comment')).toBe(true)
    transient.write('new', '   ')
    transient.capture(null)
    expect(storage.has('transient-comment')).toBe(false)
    transient[Symbol.dispose]()
  } finally {
    if (descriptor) Object.defineProperty(globalThis, 'localStorage', descriptor)
    else Reflect.deleteProperty(globalThis, 'localStorage')
  }
})
