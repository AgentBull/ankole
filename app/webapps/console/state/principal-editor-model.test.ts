import { describe, expect, test } from 'bun:test'
import { principalRequestError } from '../pages/principal-create'
import { PrincipalEditorModel } from './principal-editor-model'

describe('PrincipalEditorModel', () => {
  test('validates the create draft and builds the create body', () => {
    const model = new PrincipalEditorModel()

    model.initialize('new', { displayName: '', email: '' })
    expect(model.draftError()).toBe('display_name_required')

    model.displayName.value = 'Ada Lovelace'
    expect(model.draftError()).toBeUndefined()

    model.email.value = 'not-an-email'
    expect(model.draftError()).toBe('email_invalid')

    model.email.value = ' ada@example.com '
    expect(model.draftError()).toBeUndefined()
    expect(model.createBody()).toEqual({
      display_name: 'Ada Lovelace',
      email: 'ada@example.com',
      membership: 'member'
    })

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

  test('allows an externally observed user without email to edit the display name', () => {
    const model = new PrincipalEditorModel()

    model.initialize('principal:lark-main:alice', { displayName: 'Alice', email: '' })
    model.displayName.value = 'Alice Chen'

    expect(model.draftError()).toBeUndefined()
    expect(model.updateBody()).toEqual({ display_name: 'Alice Chen' })

    model.email.value = 'invalid'
    expect(model.draftError()).toBe('email_invalid')
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

test('creating a guest captures the selected membership without changing the profile update contract', () => {
  const model = new PrincipalEditorModel()
  model.initialize('new', { displayName: 'Guest', email: 'guest@example.com' })
  model.membership.value = 'guest'
  expect(model.dirty.value).toBe(true)
  expect(model.createBody().membership).toBe('guest')
  expect(model.updateBody()).toEqual({})
  model[Symbol.dispose]()
})

test('principalRequestError maps structured email_taken codes and details without relying solely on English text', () => {
  const t = (key: string) => key
  expect(principalRequestError({ error: { code: 'email_taken', message: '冲突' } }, t)).toBe(
    'console.principals.email_taken'
  )
  expect(
    principalRequestError(
      { errors: [{ code: 'validation_failed', meta: { details: [{ path: 'email', kind: 'taken' }] } }] },
      t
    )
  ).toBe('console.principals.email_taken')
  const unrelated = new Error('network')
  expect(principalRequestError(unrelated, t)).toBe(unrelated)
})
