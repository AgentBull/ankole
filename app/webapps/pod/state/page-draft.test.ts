import { describe, expect, test } from 'bun:test'
import { PageDraftModel } from './page-draft'

describe('page drafts', () => {
  test('remote titles never advance the base of an unconfirmed local title', () => {
    const model = new PageDraftModel('doc')
    model.load('page', '<page/>', 0, 'Original')
    model.title.value.value = 'My draft'
    model.load('page', '<page/>', 1, 'Their title')
    expect(model.title.base.value).toBe('Original')
    model.title.reject('Their title')
    expect(model.title.conflict.value).toBe(true)
    expect(model.title.value.value).toBe('My draft')
    model.title.review(false)
    expect(model.title.base.value).toBe('Their title')
    expect(model.title.value.value).toBe('My draft')
    model.title.reject('Another title')
    model.title.review(true)
    expect(model.title.value.value).toBe('Another title')
    expect(model.title.dirty.value).toBe(false)
    model[Symbol.dispose]()
  })

  test('title saves acknowledge their captured title without consuming edits made during the request', () => {
    const model = new PageDraftModel('doc')
    model.load('page', '<page/>', 0, 'Original')
    model.title.value.value = 'First edit'
    model.title.value.value = 'Latest edit'
    model.title.acknowledge('First edit', 'First edit')
    model.load('page', '<page/>', 0, 'First edit')
    expect(model.title.value.value).toBe('Latest edit')
    expect(model.title.dirty.value).toBe(true)
    model.title.acknowledge('Latest edit', 'Latest edit')
    expect(model.title.dirty.value || model.body()!.dirty.value).toBe(false)
  })

  test('a refresh cannot replace an unsaved title or document, while a clean title follows collaborators', () => {
    const model = new PageDraftModel('doc')
    model.load('page', '<page><p>Original</p></page>', 1, 'Original')
    model.load('page', '<page><p>Remote</p></page>', 2, 'Collaborator title')
    expect(model.title.value.value).toBe('Collaborator title')
    model.title.value.value = 'Local title'
    model.body()!.xml.value = '<page><p>Local</p></page>'
    model.load('page', '<page><p>New remote</p></page>', 3, 'Another title')
    expect(model.title.value.value).toBe('Local title')
    expect(model.body()!.xml.value).toBe('<page><p>Local</p></page>')
    expect(model.title.dirty.value || model.body()!.dirty.value).toBe(true)
    expect(model.title.saved.value).toBe('Another title')
  })

  test('saving the document does not mark a failed title save as saved', () => {
    const model = new PageDraftModel('doc')
    model.load('page', '<page/>', 0, 'Original')
    model.title.value.value = 'Unsaved title'
    model.body()!.xml.value = '<page><p>Changed</p></page>'
    model.body()!.saved(model.body()!.xml.value, 1, false)
    expect(model.title.dirty.value || model.body()!.dirty.value).toBe(true)
    model.title.acknowledge('Unsaved title', 'Unsaved title')
    expect(model.title.dirty.value || model.body()!.dirty.value).toBe(false)
  })

  test('a confirmed body remains available to comments while a title or recovery draft needs attention', async () => {
    const model = new PageDraftModel('doc')
    model.load('page', '<page><p>Confirmed</p></page>', 1, 'Original')
    model.title.value.value = 'Unsaved title'
    model.body()!.keepRecoveryDraft('<page><p>Kept draft</p></page>')
    expect(model.body()!.bodyReady.value).toBe(true)
    expect(model.hasUnsavedChanges.value).toBe(true)

    model.body()!.conflict.value = true
    expect(model.body()!.bodyReady.value).toBe(false)
    await model.body()!.reload(async () => ({ xml: '<page><p>Reloaded</p></page>', revision: 2 }))
    expect(model.body()!.bodyReady.value).toBe(true)
    expect(model.hasUnsavedChanges.value).toBe(true)
    expect(model.title.value.value).toBe('Unsaved title')
    expect(model.body()!.recoveryDrafts.value).toEqual(['<page><p>Kept draft</p></page>'])
    model[Symbol.dispose]()
  })

  test('an in-flight body batch blocks anchors and leaving even when local XML matches the confirmed body', () => {
    const model = new PageDraftModel('doc')
    const xml = '<page><p>Confirmed</p></page>'
    model.load('page', xml, 1, '')
    model.body()!.saved(xml, 1, true)
    expect(model.title.dirty.value || model.body()!.dirty.value).toBe(false)
    expect(model.body()!.bodyReady.value).toBe(false)
    expect(model.hasUnsavedChanges.value).toBe(true)
    model.load('page', xml, 2, '')
    expect(model.body()!.bodyPending.value).toBe(true)
    expect(model.body()!.revision.value).toBe(1)

    model.body()!.saved(xml, 2, false)
    expect(model.body()!.bodyReady.value).toBe(true)
    expect(model.hasUnsavedChanges.value).toBe(false)
    expect(model.body()!.revision.value).toBe(2)
    model.body()!.xml.value = '<page><p>Next local edit</p></page>'
    expect(model.body()!.bodyReady.value).toBe(false)
    model[Symbol.dispose]()
  })

  test('selecting another resource clears recovery data and seeds both drafts', () => {
    const model = new PageDraftModel('doc')
    model.load('first', '<page/>', 0, 'First')
    model.body()!.keepRecoveryDraft('<page><p>Recovery</p></page>')
    model.body()!.saved(model.body()!.savedXML.value, 0, true)
    model.title.value.value = 'Draft'
    model.load('second', '<page><p>Second</p></page>', 4, 'Second')
    expect(model.title.value.value).toBe('Second')
    expect(model.body()!.recoveryDrafts.value).toEqual([])
    expect(model.title.dirty.value || model.body()!.dirty.value).toBe(false)
    expect(model.body()!.bodyPending.value).toBe(false)
    expect(model.body()!.bodyReady.value).toBe(true)
  })

  test('reset recovery stays protected through reloads and later resets until explicitly discarded', async () => {
    const model = new PageDraftModel('doc')
    model.load('page', '<page/>', 0, '')
    const first = '<page><p>First local edit</p></page>'
    const second = '<page><p>Second local edit</p></page>'
    model.body()!.keepRecoveryDraft(first)
    await model.body()!.reload(async () => ({ xml: '<page><p>Remote reset</p></page>', revision: 1 }))
    expect(model.title.dirty.value || model.body()!.dirty.value).toBe(false)
    expect(model.hasUnsavedChanges.value).toBe(true)
    model.body()!.keepRecoveryDraft(second)
    await model.body()!.reload(async () => ({ xml: '<page/>', revision: 2 }))
    expect(model.body()!.recoveryDrafts.value).toEqual([first, second])
    model.body()!.discardRecoveryDraft(first)
    expect(model.hasUnsavedChanges.value).toBe(true)
    model.body()!.discardRecoveryDraft(second)
    expect(model.hasUnsavedChanges.value).toBe(false)
    model[Symbol.dispose]()
  })

  test('a late recovery cannot overwrite a newer reload or the edits that follow it', async () => {
    const model = new PageDraftModel('doc')
    model.load('page', '<page/>', 0, '')
    model.body()!.keepRecoveryDraft('<page><p>First draft</p></page>')
    const first = Promise.withResolvers<{ xml: string; revision: number }>()
    const pending = model.body()!.reload(() => first.promise)
    const latest = '<page><p>Latest remote</p></page>'
    expect(await model.body()!.reload(async () => ({ xml: latest, revision: 2 }))).toBe(latest)
    model.body()!.xml.value = '<page><p>New local edit</p></page>'
    first.resolve({ xml: '<page><p>Older remote</p></page>', revision: 1 })
    expect(await pending).toBeUndefined()
    expect(model.body()!.xml.value).toContain('New local edit')
    expect(model.body()!.savedXML.value).toBe(latest)
    expect(model.body()!.revision.value).toBe(2)
    expect(model.body()!.recoveryDrafts.value).toEqual(['<page><p>First draft</p></page>'])
    expect(model.hasUnsavedChanges.value).toBe(true)
    model[Symbol.dispose]()
  })

  test('a recovery read cannot replace edits or acknowledgements made while it is pending', async () => {
    const model = new PageDraftModel('doc')
    model.load('page', '<page/>', 1, '')
    const response = Promise.withResolvers<{ xml: string; revision: number }>()
    const pending = model.body()!.reload(() => response.promise)
    model.body()!.xml.value = '<page><p>New edit</p></page>'
    response.resolve({ xml: '<page><p>Read snapshot</p></page>', revision: 2 })
    expect(await pending).toBeUndefined()
    expect(model.body()!.xml.value).toContain('New edit')

    const older = Promise.withResolvers<{ xml: string; revision: number }>()
    const reload = model.body()!.reload(() => older.promise)
    model.body()!.saved(model.body()!.xml.value, 3, false)
    older.resolve({ xml: '<page><p>Read snapshot</p></page>', revision: 2 })
    expect(await reload).toBeUndefined()
    expect(model.body()!.savedXML.value).toContain('New edit')
    expect(model.body()!.revision.value).toBe(3)
    model[Symbol.dispose]()
  })

  test('a current failure keeps recovery available, but a superseded failure is ignored', async () => {
    const model = new PageDraftModel('doc')
    model.load('page', '<page/>', 1, '')
    model.body()!.conflict.value = true
    model.body()!.keepRecoveryDraft('<page><p>Recover me</p></page>')
    await expect(
      model.body()!.reload(async () => {
        throw new Error('Read failed')
      })
    ).rejects.toThrow('Read failed')
    expect(model.body()!.conflict.value).toBe(true)
    expect(model.hasUnsavedChanges.value).toBe(true)

    const response = Promise.withResolvers<{ xml: string; revision: number }>()
    const pending = model.body()!.reload(() => response.promise)
    await model.body()!.reload(async () => ({ xml: '<page><p>Recovered</p></page>', revision: 2 }))
    response.reject(new Error('Old read failed'))
    expect(await pending).toBeUndefined()
    expect(model.body()!.conflict.value).toBe(false)
    expect(model.body()!.recoveryDrafts.value).toHaveLength(1)
    model[Symbol.dispose]()
  })

  test('changing source or closing the editor revokes a pending recovery', async () => {
    for (const close of [false, true]) {
      const model = new PageDraftModel('doc')
      model.load('first', '<page/>', 1, '')
      const response = Promise.withResolvers<{ xml: string; revision: number }>()
      const pending = model.body()!.reload(() => response.promise)
      if (close) model.body()!.cancelReload()
      else model.load('second', '<page/>', 0, '')
      response.resolve({ xml: '<page><p>Wrong editor</p></page>', revision: 2 })
      expect(await pending).toBeUndefined()
      expect(model.body()!.xml.value).toBe('<page/>')
      expect(model.body()!.revision.value).toBe(close ? 1 : 0)
      model[Symbol.dispose]()
    }
  })
})

test('reloading keeps unconfirmed drafts separate from the latest server document', () => {
  const originalStorage = Object.getOwnPropertyDescriptor(globalThis, 'sessionStorage')
  const data = new Map<string, string>()
  Object.defineProperty(globalThis, 'sessionStorage', {
    configurable: true,
    value: {
      getItem: (key: string) => data.get(key) ?? null,
      setItem: (key: string, value: string) => data.set(key, value),
      removeItem: (key: string) => data.delete(key)
    }
  })
  try {
    const first = new PageDraftModel('doc', 'draft')
    first.load('page', '<page><p>Original</p></page>', 1, 'Original')
    first.body()!.xml.value = '<page><p>Offline changes</p></page>'
    first.title.value.value = 'Local title'
    first.persist()
    first[Symbol.dispose]()

    const reloaded = new PageDraftModel('doc', 'draft')
    reloaded.load('page', '<page><p>Collaborator changes</p></page>', 2, 'Remote title')
    expect(reloaded.body()!.xml.value).toBe('<page><p>Collaborator changes</p></page>')
    expect(reloaded.body()!.recoveryDrafts.value).toEqual(['<page><p>Offline changes</p></page>'])
    expect(reloaded.title.value.value).toBe('Local title')
    expect(reloaded.title.base.value).toBe('Original')
    expect(reloaded.title.conflict.value).toBe(true)
    reloaded.persist()
    reloaded[Symbol.dispose]()

    const again = new PageDraftModel('doc', 'draft')
    again.load('page', '<page><p>Collaborator changes</p></page>', 2, 'Remote title')
    expect(again.body()!.recoveryDrafts.value).toEqual(['<page><p>Offline changes</p></page>'])
    again.discard()
    again.persist()
    expect(data.has('draft')).toBe(false)
    again[Symbol.dispose]()

    data.set(
      'draft',
      JSON.stringify({
        xml: '<page><p>Committed</p></page>',
        savedXML: '<page/>',
        title: 'Committed',
        savedTitle: 'Original',
        titleBase: 'Original'
      })
    )
    const acknowledged = new PageDraftModel('doc', 'draft')
    acknowledged.load('page', '<page><p>Committed</p></page>', 3, 'Committed')
    expect(acknowledged.hasUnsavedChanges.value).toBe(false)
    acknowledged.persist()
    expect(data.has('draft')).toBe(false)
    acknowledged[Symbol.dispose]()

    data.set('draft', JSON.stringify({ xml: '<page/>', savedXML: '<page/>', pending: true }))
    const undoPending = new PageDraftModel('doc', 'draft')
    undoPending.load('page', '<page><p>Submitted before undo</p></page>', 4, '')
    expect(undoPending.body()!.recoveryDrafts.value).toEqual(['<page/>'])
    undoPending[Symbol.dispose]()
  } finally {
    if (originalStorage) Object.defineProperty(globalThis, 'sessionStorage', originalStorage)
    else Reflect.deleteProperty(globalThis, 'sessionStorage')
  }
})

test('unavailable browser storage leaves the draft available and reports the recovery limitation', () => {
  const originalStorage = Object.getOwnPropertyDescriptor(globalThis, 'sessionStorage')
  Object.defineProperty(globalThis, 'sessionStorage', {
    configurable: true,
    get() {
      throw new Error('Storage blocked')
    }
  })
  try {
    const model = new PageDraftModel('doc', 'blocked')
    model.load('page', '<page/>', 0, '')
    model.body()!.xml.value = '<page><p>Keep me</p></page>'
    model.persist()
    expect(model.storageError.value).toBe(true)
    expect(model.body()!.xml.value).toContain('Keep me')
    expect(model.hasUnsavedChanges.value).toBe(true)
    model[Symbol.dispose]()
  } finally {
    if (originalStorage) Object.defineProperty(globalThis, 'sessionStorage', originalStorage)
    else Reflect.deleteProperty(globalThis, 'sessionStorage')
  }
})

test('a canonical saved title settles the submitted draft without overwriting a newer edit', () => {
  const model = new PageDraftModel('doc')
  model.load('page', '', 1, 'Original')
  model.title.value.value = 'A\u202a title'
  model.title.acknowledge('A title', 'A\u202a title')
  expect(model.title.value.value).toBe('A title')
  expect(model.title.dirty.value).toBe(false)
  model.title.value.value = 'Next edit'
  model.title.acknowledge('Older title', 'Older\u200e title')
  expect(model.title.value.value).toBe('Next edit')
  expect(model.title.dirty.value).toBe(true)
})

function withDraftStorage(run: (data: Map<string, string>) => void) {
  const previous = Object.getOwnPropertyDescriptor(globalThis, 'sessionStorage')
  const data = new Map<string, string>()
  Object.defineProperty(globalThis, 'sessionStorage', {
    configurable: true,
    value: {
      getItem: (key: string) => data.get(key) ?? null,
      setItem: (key: string, value: string) => data.set(key, value),
      removeItem: (key: string) => data.delete(key)
    }
  })
  try {
    run(data)
  } finally {
    if (previous) Object.defineProperty(globalThis, 'sessionStorage', previous)
    else Reflect.deleteProperty(globalThis, 'sessionStorage')
  }
}

test('file, Base and Applet titles recover existing drafts without creating or persisting XML state', () => {
  withDraftStorage(data => {
    for (const type of ['file', 'base', 'applet'] as const) {
      data.set(
        'draft',
        JSON.stringify({
          title: 'Local title',
          savedTitle: 'Original',
          titleBase: 'Original',
          xml: '<page/>',
          savedXML: '<page/>'
        })
      )
      const model = new PageDraftModel(type, 'draft')
      model.load('page', '<page/>', 8, 'Remote title')
      expect(model.title.value.value).toBe('Local title')
      expect(model.title.base.value).toBe('Original')
      expect(model.title.conflict.value).toBe(true)
      expect(model.body()).toBeUndefined()
      expect(model.properties()).toBeUndefined()
      expect(model.hasUnsavedChanges.value).toBe(true)
      model.persist()
      expect(JSON.parse(data.get('draft')!)).toEqual({
        title: 'Local title',
        savedTitle: 'Remote title',
        titleBase: 'Original'
      })
      model.title.review(false)
      model.title.acknowledge('Local title', 'Local title')
      model.persist()
      expect(data.has('draft')).toBe(false)
      model[Symbol.dispose]()
    }
  })
})

test('knowledge recovery preserves XML, the original revision and even invalid property input together', () => {
  withDraftStorage(data => {
    const first = new PageDraftModel('knowledge', 'draft')
    first.load('page', '<page><p>Original</p></page>', 3, 'Title')
    const properties = first.properties()!
    properties.begin({ custom: { unknown: true } })
    properties.change(0, { source: '[' })
    expect(first.hasUnsavedChanges.value).toBe(true)
    expect(first.body()!.bodyPending.value).toBe(false)
    first.body()!.xml.value = '<page><p>Unsaved body</p></page>'
    first.persist()
    first[Symbol.dispose]()

    const restored = new PageDraftModel('knowledge', 'draft')
    restored.load('page', '<page><p>Collaborator body</p></page>', 4, 'Title')
    expect(restored.body()!.xml.value).toContain('Unsaved body')
    expect(restored.body()!.revision.value).toBe(3)
    expect(restored.properties()!.entries.value).toEqual([{ key: 'custom', source: '[' }])
    expect(restored.properties()!.parsed.value.error).not.toBeNull()
    expect(restored.hasUnsavedChanges.value).toBe(true)
    restored.discard()
    restored.persist()
    expect(restored.hasUnsavedChanges.value).toBe(false)
    expect(data.has('draft')).toBe(false)
    restored[Symbol.dispose]()
  })
})
