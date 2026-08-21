import { describe, expect, test } from 'bun:test'
import { PrincipalEditorModel } from './principal-editor-model'

describe('PrincipalEditorModel', () => {
  test('validates the create draft and builds the create body', () => {
    const model = new PrincipalEditorModel()

    model.initialize('new', { displayName: '', email: '' })
    expect(model.draftError()).toBe('display_name_required')

    model.displayName.value = 'Ada Lovelace'
    expect(model.draftError()).toBe('email_required')

    model.email.value = 'not-an-email'
    expect(model.draftError()).toBe('email_invalid')

    model.email.value = ' ada@example.com '
    expect(model.draftError()).toBeUndefined()
    expect(model.createBody()).toEqual({
      display_name: 'Ada Lovelace',
      email: 'ada@example.com',
      must_change_password: true
    })

    model.mustChangePassword.value = false
    expect(model.createBody().must_change_password).toBe(false)
    model[Symbol.dispose]()
  })

  test('sends only changed fields on update and tracks dirtiness', () => {
    const model = new PrincipalEditorModel()

    model.initialize('principal:u1', { displayName: 'Ada', email: 'ada@example.com' })
    expect(model.dirty.value).toBe(false)
    expect(model.updateBody()).toEqual({})

    model.displayName.value = 'Ada L.'
    expect(model.dirty.value).toBe(true)
    expect(model.updateBody()).toEqual({ display_name: 'Ada L.' })

    model.email.value = 'ada.l@example.com'
    expect(model.updateBody()).toEqual({ display_name: 'Ada L.', email: 'ada.l@example.com' })
    model[Symbol.dispose]()
  })

  test('keeps edits during refetch and resets for another principal', () => {
    const model = new PrincipalEditorModel()

    model.initialize('principal:u1', { displayName: 'Ada', email: 'ada@example.com' })
    model.displayName.value = 'Edited'
    model.initialize('principal:u1', { displayName: 'Refetched', email: 'ada@example.com' })
    expect(model.displayName.value).toBe('Edited')

    model.initialize('principal:u2', { displayName: 'Grace', email: 'grace@example.com' })
    expect(model.displayName.value).toBe('Grace')
    expect(model.dirty.value).toBe(false)
    model[Symbol.dispose]()
  })
})
