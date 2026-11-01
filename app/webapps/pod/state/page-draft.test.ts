import { describe, expect, test } from 'bun:test'
import { PageDraftModel } from './page-draft'

describe('page drafts', () => {
  test('remote titles never advance the base of an unconfirmed local title', () => {
    const model = new PageDraftModel()
    model.load('page', '<page/>', 0, 'Original')
    model.title.value = 'My draft'
    model.load('page', '<page/>', 1, 'Their title')
    expect(model.titleBase.value).toBe('Original')
    model.titleRejected('Their title')
    expect(model.titleConflict.value).toBe(true)
    expect(model.title.value).toBe('My draft')
    model.reviewTitle(false)
    expect(model.titleBase.value).toBe('Their title')
    expect(model.title.value).toBe('My draft')
    model.titleRejected('Another title')
    model.reviewTitle(true)
    expect(model.title.value).toBe('Another title')
    expect(model.titleDirty.value).toBe(false)
    model[Symbol.dispose]()
  })

  test('title saves acknowledge their captured title without consuming edits made during the request', () => {
    const model = new PageDraftModel()
    model.load('page', '<page/>', 0, 'Original')
    model.title.value = 'First edit'
    model.title.value = 'Latest edit'
    model.titleSaved('First edit', 'First edit')
    model.load('page', '<page/>', 0, 'First edit')
    expect(model.title.value).toBe('Latest edit')
    expect(model.titleDirty.value).toBe(true)
    model.titleSaved('Latest edit', 'Latest edit')
    expect(model.dirty.value).toBe(false)
  })

  test('a refresh cannot replace an unsaved title or document, while a clean title follows collaborators', () => {
    const model = new PageDraftModel()
    model.load('page', '<page><p>Original</p></page>', 1, 'Original')
    model.load('page', '<page><p>Remote</p></page>', 2, 'Collaborator title')
    expect(model.title.value).toBe('Collaborator title')
    model.title.value = 'Local title'
    model.xml.value = '<page><p>Local</p></page>'
    model.load('page', '<page><p>New remote</p></page>', 3, 'Another title')
    expect(model.title.value).toBe('Local title')
    expect(model.xml.value).toBe('<page><p>Local</p></page>')
    expect(model.dirty.value).toBe(true)
    expect(model.savedTitle.value).toBe('Another title')
  })

  test('saving the document does not mark a failed title save as saved', () => {
    const model = new PageDraftModel()
    model.load('page', '<page/>', 0, 'Original')
    model.title.value = 'Unsaved title'
    model.xml.value = '<page><p>Changed</p></page>'
    model.saved(model.xml.value, 1, false)
    expect(model.dirty.value).toBe(true)
    model.titleSaved('Unsaved title', 'Unsaved title')
    expect(model.dirty.value).toBe(false)
  })

  test('a confirmed body remains available to comments while a title or recovery draft needs attention', async () => {
    const model = new PageDraftModel()
    model.load('page', '<page><p>Confirmed</p></page>', 1, 'Original')
    model.title.value = 'Unsaved title'
    model.keepRecoveryDraft('<page><p>Kept draft</p></page>')
    expect(model.bodyReady.value).toBe(true)
    expect(model.hasUnsavedChanges.value).toBe(true)

    model.conflict.value = true
    expect(model.bodyReady.value).toBe(false)
    await model.reload(async () => ({ xml: '<page><p>Reloaded</p></page>', revision: 2 }))
    expect(model.bodyReady.value).toBe(true)
    expect(model.hasUnsavedChanges.value).toBe(true)
    expect(model.title.value).toBe('Unsaved title')
    expect(model.recoveryDrafts.value).toEqual(['<page><p>Kept draft</p></page>'])
    model[Symbol.dispose]()
  })

  test('an in-flight body batch blocks anchors and leaving even when local XML matches the confirmed body', () => {
    const model = new PageDraftModel()
    const xml = '<page><p>Confirmed</p></page>'
    model.load('page', xml, 1)
    model.saved(xml, 1, true)
    expect(model.dirty.value).toBe(false)
    expect(model.bodyReady.value).toBe(false)
    expect(model.hasUnsavedChanges.value).toBe(true)
    model.load('page', xml, 2)
    expect(model.bodyPending.value).toBe(true)
    expect(model.revision.value).toBe(1)

    model.saved(xml, 2, false)
    expect(model.bodyReady.value).toBe(true)
    expect(model.hasUnsavedChanges.value).toBe(false)
    expect(model.revision.value).toBe(2)
    model.xml.value = '<page><p>Next local edit</p></page>'
    expect(model.bodyReady.value).toBe(false)
    model[Symbol.dispose]()
  })

  test('selecting another resource clears recovery data and seeds both drafts', () => {
    const model = new PageDraftModel()
    model.load('first', '<page/>', 0, 'First')
    model.keepRecoveryDraft('<page><p>Recovery</p></page>')
    model.saved(model.savedXML.value, 0, true)
    model.title.value = 'Draft'
    model.load('second', '<page><p>Second</p></page>', 4, 'Second')
    expect(model.title.value).toBe('Second')
    expect(model.recoveryDrafts.value).toEqual([])
    expect(model.dirty.value).toBe(false)
    expect(model.bodyPending.value).toBe(false)
    expect(model.bodyReady.value).toBe(true)
  })

  test('reset recovery stays protected through reloads and later resets until explicitly discarded', async () => {
    const model = new PageDraftModel()
    model.load('page', '<page/>', 0)
    const first = '<page><p>First local edit</p></page>'
    const second = '<page><p>Second local edit</p></page>'
    model.keepRecoveryDraft(first)
    await model.reload(async () => ({ xml: '<page><p>Remote reset</p></page>', revision: 1 }))
    expect(model.dirty.value).toBe(false)
    expect(model.hasUnsavedChanges.value).toBe(true)
    model.keepRecoveryDraft(second)
    await model.reload(async () => ({ xml: '<page/>', revision: 2 }))
    expect(model.recoveryDrafts.value).toEqual([first, second])
    model.discardRecoveryDraft(first)
    expect(model.hasUnsavedChanges.value).toBe(true)
    model.discardRecoveryDraft(second)
    expect(model.hasUnsavedChanges.value).toBe(false)
    model[Symbol.dispose]()
  })

  test('a late recovery cannot overwrite a newer reload or the edits that follow it', async () => {
    const model = new PageDraftModel()
    model.load('page', '<page/>', 0)
    model.keepRecoveryDraft('<page><p>First draft</p></page>')
    const first = Promise.withResolvers<{ xml: string; revision: number }>()
    const pending = model.reload(() => first.promise)
    const latest = '<page><p>Latest remote</p></page>'
    expect(await model.reload(async () => ({ xml: latest, revision: 2 }))).toBe(latest)
    model.xml.value = '<page><p>New local edit</p></page>'
    first.resolve({ xml: '<page><p>Older remote</p></page>', revision: 1 })
    expect(await pending).toBeUndefined()
    expect(model.xml.value).toContain('New local edit')
    expect(model.savedXML.value).toBe(latest)
    expect(model.revision.value).toBe(2)
    expect(model.recoveryDrafts.value).toEqual(['<page><p>First draft</p></page>'])
    expect(model.hasUnsavedChanges.value).toBe(true)
    model[Symbol.dispose]()
  })

  test('a recovery read cannot replace edits or acknowledgements made while it is pending', async () => {
    const model = new PageDraftModel()
    model.load('page', '<page/>', 1)
    const response = Promise.withResolvers<{ xml: string; revision: number }>()
    const pending = model.reload(() => response.promise)
    model.xml.value = '<page><p>New edit</p></page>'
    response.resolve({ xml: '<page><p>Read snapshot</p></page>', revision: 2 })
    expect(await pending).toBeUndefined()
    expect(model.xml.value).toContain('New edit')

    const older = Promise.withResolvers<{ xml: string; revision: number }>()
    const reload = model.reload(() => older.promise)
    model.saved(model.xml.value, 3, false)
    older.resolve({ xml: '<page><p>Read snapshot</p></page>', revision: 2 })
    expect(await reload).toBeUndefined()
    expect(model.savedXML.value).toContain('New edit')
    expect(model.revision.value).toBe(3)
    model[Symbol.dispose]()
  })

  test('a current failure keeps recovery available, but a superseded failure is ignored', async () => {
    const model = new PageDraftModel()
    model.load('page', '<page/>', 1)
    model.conflict.value = true
    model.keepRecoveryDraft('<page><p>Recover me</p></page>')
    await expect(
      model.reload(async () => {
        throw new Error('Read failed')
      })
    ).rejects.toThrow('Read failed')
    expect(model.conflict.value).toBe(true)
    expect(model.hasUnsavedChanges.value).toBe(true)

    const response = Promise.withResolvers<{ xml: string; revision: number }>()
    const pending = model.reload(() => response.promise)
    await model.reload(async () => ({ xml: '<page><p>Recovered</p></page>', revision: 2 }))
    response.reject(new Error('Old read failed'))
    expect(await pending).toBeUndefined()
    expect(model.conflict.value).toBe(false)
    expect(model.recoveryDrafts.value).toHaveLength(1)
    model[Symbol.dispose]()
  })

  test('changing source or closing the editor revokes a pending recovery', async () => {
    for (const close of [false, true]) {
      const model = new PageDraftModel()
      model.load('first', '<page/>', 1)
      const response = Promise.withResolvers<{ xml: string; revision: number }>()
      const pending = model.reload(() => response.promise)
      if (close) model.cancelReload()
      else model.load('second', '<page/>', 0)
      response.resolve({ xml: '<page><p>Wrong editor</p></page>', revision: 2 })
      expect(await pending).toBeUndefined()
      expect(model.xml.value).toBe('<page/>')
      expect(model.revision.value).toBe(close ? 1 : 0)
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
    const first = new PageDraftModel('draft')
    first.load('page', '<page><p>Original</p></page>', 1, 'Original')
    first.xml.value = '<page><p>Offline changes</p></page>'
    first.title.value = 'Local title'
    first.persist()
    first[Symbol.dispose]()

    const reloaded = new PageDraftModel('draft')
    reloaded.load('page', '<page><p>Collaborator changes</p></page>', 2, 'Remote title')
    expect(reloaded.xml.value).toBe('<page><p>Collaborator changes</p></page>')
    expect(reloaded.recoveryDrafts.value).toEqual(['<page><p>Offline changes</p></page>'])
    expect(reloaded.title.value).toBe('Local title')
    expect(reloaded.titleBase.value).toBe('Original')
    expect(reloaded.titleConflict.value).toBe(true)
    reloaded.persist()
    reloaded[Symbol.dispose]()

    const again = new PageDraftModel('draft')
    again.load('page', '<page><p>Collaborator changes</p></page>', 2, 'Remote title')
    expect(again.recoveryDrafts.value).toEqual(['<page><p>Offline changes</p></page>'])
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
    const acknowledged = new PageDraftModel('draft')
    acknowledged.load('page', '<page><p>Committed</p></page>', 3, 'Committed')
    expect(acknowledged.hasUnsavedChanges.value).toBe(false)
    acknowledged.persist()
    expect(data.has('draft')).toBe(false)
    acknowledged[Symbol.dispose]()

    data.set('draft', JSON.stringify({ xml: '<page/>', savedXML: '<page/>', pending: true }))
    const undoPending = new PageDraftModel('draft')
    undoPending.load('page', '<page><p>Submitted before undo</p></page>', 4)
    expect(undoPending.recoveryDrafts.value).toEqual(['<page/>'])
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
    const model = new PageDraftModel('blocked')
    model.load('page', '<page/>', 0)
    model.xml.value = '<page><p>Keep me</p></page>'
    model.persist()
    expect(model.storageError.value).toBe(true)
    expect(model.xml.value).toContain('Keep me')
    expect(model.hasUnsavedChanges.value).toBe(true)
    model[Symbol.dispose]()
  } finally {
    if (originalStorage) Object.defineProperty(globalThis, 'sessionStorage', originalStorage)
    else Reflect.deleteProperty(globalThis, 'sessionStorage')
  }
})

test('a canonical saved title settles the submitted draft without overwriting a newer edit', () => {
  const model = new PageDraftModel()
  model.load('page', '', 1, 'Original')
  model.title.value = 'A\u202a title'
  model.titleSaved('A title', 'A\u202a title')
  expect(model.title.value).toBe('A title')
  expect(model.titleDirty.value).toBe(false)
  model.title.value = 'Next edit'
  model.titleSaved('Older title', 'Older\u200e title')
  expect(model.title.value).toBe('Next edit')
  expect(model.titleDirty.value).toBe(true)
})
