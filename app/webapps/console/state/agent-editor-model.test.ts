import { describe, expect, test } from 'bun:test'
import { AgentEditorModel } from './agent-editor-model'

describe('AgentEditorModel', () => {
  test('keeps edits during refetch and resets when the route selects another agent', () => {
    const model = new AgentEditorModel()

    model.initialize('agent:alpha', {
      uid: 'alpha',
      displayName: 'Alpha',
      avatarURL: '',
      role: 'Research Analyst'
    })
    model.displayName.value = 'Edited Alpha'
    model.initialize('agent:alpha', {
      uid: 'alpha',
      displayName: 'Refetched Alpha',
      avatarURL: '',
      role: 'Research Analyst'
    })

    expect(model.displayName.value).toBe('Edited Alpha')

    model.initialize('agent:beta', {
      uid: 'beta',
      displayName: 'Beta',
      avatarURL: '',
      role: 'Operator'
    })

    expect(model.uid.value).toBe('beta')
    expect(model.role.value).toBe('Operator')
    expect(model.validationError.value).toBeUndefined()
    model[Symbol.dispose]()
  })
})
