import { describe, expect, test } from 'bun:test'
import { PermissionGrantEditorModel } from './permission-grant-editor-model'

describe('PermissionGrantEditorModel', () => {
  test('keeps edits during refetch and resets when the route selects another grant', () => {
    const model = new PermissionGrantEditorModel()

    model.initialize('grant:1', { resourcePattern: 'workspace:**', action: 'read', condition: 'true', description: '' })
    model.action.value = 'update'
    model.initialize('grant:1', { resourcePattern: 'workspace:**', action: 'read', condition: 'true', description: '' })

    expect(model.action.value).toBe('update')

    model.initialize('grant:2', {
      resourcePattern: 'chat:channel:*',
      action: 'read',
      condition: "principal.type == 'human'",
      description: 'Channels'
    })

    expect(model.resourcePattern.value).toBe('chat:channel:*')
    expect(model.condition.value).toBe("principal.type == 'human'")
    expect(model.validationError.value).toBeUndefined()
    model[Symbol.dispose]()
  })

  test('draftError requires a resource pattern and a colon-free action token', () => {
    const model = new PermissionGrantEditorModel()

    model.initialize('new', { resourcePattern: '', action: '', condition: 'true', description: '' })
    expect(model.draftError()).toBe('resource_pattern_required')

    model.resourcePattern.value = 'workspace:**'
    expect(model.draftError()).toBe('action_required')

    model.action.value = 'workspace:read'
    expect(model.draftError()).toBe('action_no_colon')

    model.action.value = 'read'
    expect(model.draftError()).toBeUndefined()
    model[Symbol.dispose]()
  })

  test('createBody targets exactly one owner and defaults the condition', () => {
    const model = new PermissionGrantEditorModel()

    model.initialize('new', { resourcePattern: ' workspace:** ', action: ' read ', condition: '  ', description: '' })

    expect(model.createBody({ principalUID: 'u-1' })).toEqual({
      principal_uid: 'u-1',
      resource_pattern: 'workspace:**',
      action: 'read',
      condition: 'true',
      description: null
    })
    expect(model.createBody({ groupName: 'admins' })).toEqual({
      group_name: 'admins',
      resource_pattern: 'workspace:**',
      action: 'read',
      condition: 'true',
      description: null
    })
    expect(model.updateBody()).toEqual({
      resource_pattern: 'workspace:**',
      action: 'read',
      condition: 'true',
      description: null
    })
    model[Symbol.dispose]()
  })
})
