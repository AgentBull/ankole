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

  test('reset recovery stays protected through reloads and later resets until explicitly discarded', () => {
    const model = new PageDraftModel()
    model.load('page', '<page/>', 0)
    const first = '<page><p>First local edit</p></page>'
    const second = '<page><p>Second local edit</p></page>'
    model.keepRecoveryDraft(first)
    model.reload('<page><p>Remote reset</p></page>', 1)
    expect(model.dirty.value).toBe(false)
    expect(model.hasUnsavedChanges.value).toBe(true)
    model.keepRecoveryDraft(second)
    model.reload('<page/>', 2)
    expect(model.recoveryDrafts.value).toEqual([first, second])
    model.discardRecoveryDraft(first)
    expect(model.hasUnsavedChanges.value).toBe(true)
    model.discardRecoveryDraft(second)
    expect(model.hasUnsavedChanges.value).toBe(false)
    model[Symbol.dispose]()
  })
})
