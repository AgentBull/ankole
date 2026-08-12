import { describe, expect, test } from 'bun:test'
import { PrincipalGroupEditorModel } from './principal-group-editor-model'

describe('PrincipalGroupEditorModel', () => {
  test('keeps edits during refetch and resets when the route selects another group', () => {
    const model = new PrincipalGroupEditorModel()

    model.initialize('group:admins', {
      name: 'admins',
      displayName: 'Admins',
      description: '',
      kind: 'static',
      computedCondition: ''
    })
    expect(model.dirty.value).toBe(false)
    model.displayName.value = 'Edited Admins'
    expect(model.dirty.value).toBe(true)
    model.initialize('group:admins', {
      name: 'admins',
      displayName: 'Refetched Admins',
      description: '',
      kind: 'static',
      computedCondition: ''
    })

    expect(model.displayName.value).toBe('Edited Admins')

    model.initialize('group:operators', {
      name: 'operators',
      displayName: 'Operators',
      description: '',
      kind: 'computed',
      computedCondition: "principal.type == 'human'"
    })

    expect(model.name.value).toBe('operators')
    expect(model.kind.value).toBe('computed')
    expect(model.computedCondition.value).toBe("principal.type == 'human'")
    expect(model.validationError.value).toBeUndefined()
    expect(model.dirty.value).toBe(false)
    model[Symbol.dispose]()
  })

  test('markSaved converges fields and baseline on the server-normalized form', () => {
    const model = new PrincipalGroupEditorModel()

    model.initialize('group:admins', {
      name: 'admins',
      displayName: 'Admins',
      description: '',
      kind: 'static',
      computedCondition: ''
    })
    // Trailing whitespace survives in the field but the server stores it trimmed.
    model.displayName.value = 'Renamed Admins '
    expect(model.dirty.value).toBe(true)

    model.markSaved({
      name: 'admins',
      displayName: 'Renamed Admins',
      description: '',
      kind: 'static',
      computedCondition: ''
    })

    expect(model.displayName.value).toBe('Renamed Admins')
    expect(model.dirty.value).toBe(false)
    model[Symbol.dispose]()
  })

  test('draftError requires a lowercase name on create but not on edit', () => {
    const model = new PrincipalGroupEditorModel()

    model.initialize('new', { name: '', displayName: '', description: '', kind: 'static', computedCondition: '' })
    expect(model.draftError('new')).toBe('name_required')

    model.name.value = 'Operators'
    expect(model.draftError('new')).toBe('name_lowercase')

    model.name.value = 'operators'
    expect(model.draftError('new')).toBe('display_name_required')

    model.displayName.value = 'Operators'
    expect(model.draftError('new')).toBeUndefined()
    // The server owns the immutable name on edit, so an empty draft name is fine.
    expect(model.draftError('edit')).toBeUndefined()
    model[Symbol.dispose]()
  })

  test('draftError requires a condition only for computed groups', () => {
    const model = new PrincipalGroupEditorModel()

    model.initialize('new', {
      name: 'ops',
      displayName: 'Ops',
      description: '',
      kind: 'computed',
      computedCondition: ''
    })
    expect(model.draftError('new')).toBe('condition_required')

    model.computedCondition.value = "principal.status == 'active'"
    expect(model.draftError('new')).toBeUndefined()

    model.kind.value = 'static'
    model.computedCondition.value = ''
    expect(model.draftError('new')).toBeUndefined()
    model[Symbol.dispose]()
  })

  test('createBody carries name and kind; updateBody drops immutable fields', () => {
    const model = new PrincipalGroupEditorModel()

    model.initialize('new', {
      name: ' operators ',
      displayName: ' Operators ',
      description: '',
      kind: 'computed',
      computedCondition: " principal.type == 'human' "
    })

    expect(model.createBody()).toEqual({
      name: 'operators',
      display_name: 'Operators',
      description: null,
      kind: 'computed',
      computed_condition: "principal.type == 'human'"
    })
    expect(model.updateBody()).toEqual({
      display_name: 'Operators',
      description: null,
      computed_condition: "principal.type == 'human'"
    })

    model.kind.value = 'static'
    expect(model.createBody().computed_condition).toBeNull()
    expect(model.updateBody().computed_condition).toBeNull()
    model[Symbol.dispose]()
  })
})
