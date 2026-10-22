import { describe, expect, test } from 'bun:test'
import { PageDraftModel } from './page-draft'

describe('page drafts', () => {
  test('title saves acknowledge their captured title without consuming edits made during the request', () => {
    const model = new PageDraftModel()
    model.load('page', '<page/>', 0, 'Original')
    model.title.value = 'First edit'
    model.title.value = 'Latest edit'
    model.titleSaved('First edit')
    model.load('page', '<page/>', 0, 'First edit')
    expect(model.title.value).toBe('Latest edit')
    expect(model.titleDirty.value).toBe(true)
    model.titleSaved('Latest edit')
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
    model.saved(model.xml.value, 1)
    expect(model.dirty.value).toBe(true)
    model.titleSaved('Unsaved title')
    expect(model.dirty.value).toBe(false)
  })

  test('selecting another resource clears recovery data and seeds both drafts', () => {
    const model = new PageDraftModel()
    model.load('first', '<page/>', 0, 'First')
    model.keepRecoveryDraft('<page><p>Recovery</p></page>')
    model.title.value = 'Draft'
    model.load('second', '<page><p>Second</p></page>', 4, 'Second')
    expect(model.title.value).toBe('Second')
    expect(model.recoveryDrafts.value).toEqual([])
    expect(model.dirty.value).toBe(false)
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
    model.saved(model.xml.value, 3)
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
