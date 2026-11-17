import { describe, expect, test } from 'bun:test'
import { PrincipalEditorModel, principalDraftErrorText, principalRequestError } from './principal-editor-model'

describe('PrincipalEditorModel', () => {
  test('sends only changed fields on update and tracks dirtiness', () => {
    const model = new PrincipalEditorModel()

    model.initialize('tenant-1:principal:u1', { displayName: 'Ada', email: 'ada@example.com' })
    expect(model.dirty.value).toBe(false)
    expect(model.updateBody()).toEqual({})

    model.displayName.value = 'Ada L.'
    expect(model.dirty.value).toBe(true)
    expect(model.updateBody()).toEqual({ display_name: 'Ada L.' })

    model.email.value = 'ada.l@example.com'
    expect(model.updateBody()).toEqual({ display_name: 'Ada L.', email: 'ada.l@example.com' })
    model[Symbol.dispose]()
  })

  test('allows an externally observed user without email to edit the display name and rejects blank display name or invalid email', () => {
    const model = new PrincipalEditorModel()

    model.initialize('tenant-1:principal:lark-main:alice', { displayName: '', email: '' })
    expect(model.draftError()).toBe('display_name_required')

    model.displayName.value = 'Alice Chen'
    expect(model.draftError()).toBeUndefined()
    expect(model.updateBody()).toEqual({ display_name: 'Alice Chen' })

    model.email.value = 'invalid'
    expect(model.draftError()).toBe('email_invalid')

    model.email.value = ' alice@example.com '
    expect(model.draftError()).toBeUndefined()
    model[Symbol.dispose]()
  })

  test('keeps edits during refetch and resets for another principal or tenant', async () => {
    const model = new PrincipalEditorModel()

    model.initialize('tenant-1:principal:u1', { displayName: 'Ada', email: 'ada@example.com' })
    model.displayName.value = 'Edited'
    model.initialize('tenant-1:principal:u1', { displayName: 'Refetched', email: 'ada@example.com' })
    expect(model.displayName.value).toBe('Edited')

    model.initialize('tenant-2:principal:u1', { displayName: 'Grace', email: 'grace@example.com' })
    expect(model.displayName.value).toBe('Grace')
    expect(model.dirty.value).toBe(false)

    let savedClean: boolean | undefined
    model.displayName.value = 'Grace Hopper'
    await model.save(
      async () => {},
      clean => {
        savedClean = clean
      }
    )
    expect(savedClean).toBe(true)
    expect(model.dirty.value).toBe(false)
    model[Symbol.dispose]()
  })
})

test('principalDraftErrorText and principalRequestError map validation and email_taken failures cleanly', () => {
  const t = (key: string) => key
  expect(principalDraftErrorText('display_name_required', t)).toBe('common.field_required')
  expect(principalDraftErrorText('email_invalid', t)).toBe('common.email_invalid')
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
