import { beforeAll, describe, expect, test } from 'bun:test'
import { AgentEditorModel, agentUIDError, agentUIDFromDisplayName, preloadTransliteration } from './agent-editor-model'

// UID derivation upgrades from an ASCII-only fallback once the on-demand
// transliteration table loads; the assertions cover the loaded behavior.
beforeAll(() => preloadTransliteration())

describe('AgentEditorModel', () => {
  test('keeps edits during refetch and resets when the route selects another agent', () => {
    const model = new AgentEditorModel()

    model.initialize('agent:alpha', {
      uid: 'alpha',
      displayName: 'Alpha',
      avatarURL: '',
      role: 'Research Analyst'
    })
    expect(model.dirty.value).toBe(false)
    model.displayName.value = 'Edited Alpha'
    expect(model.dirty.value).toBe(true)
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
    expect(model.dirty.value).toBe(false)
    model[Symbol.dispose]()
  })

  test('reports the required display name, UID, and role before submission', () => {
    const model = new AgentEditorModel()

    model.initialize('new', {
      uid: '',
      displayName: '',
      avatarURL: '',
      role: ''
    })
    expect(model.draftError('new')).toBe('display_name_required')

    model.displayName.value = 'Research Analyst'
    expect(model.draftError('new')).toBe('uid_required')
    model.uid.value = 'research-analyst'
    model.role.value = '  '
    expect(model.draftError('new')).toBe('role_required')
    expect(model.draftError('edit')).toBe('role_required')

    model.role.value = 'Research Analyst'
    expect(model.draftError('new')).toBeUndefined()
    model[Symbol.dispose]()
  })

  test('loads a legacy agent without a display name and requires it on the next edit', () => {
    const model = new AgentEditorModel()

    model.initialize('agent:legacy-agent', {
      uid: 'legacy-agent',
      displayName: '',
      avatarURL: '',
      role: 'Legacy Operator'
    })

    expect(model.uid.value).toBe('legacy-agent')
    expect(model.draftError('edit')).toBe('display_name_required')

    model.setDisplayName('Legacy Agent', false)
    expect(model.uid.value).toBe('legacy-agent')
    expect(model.draftError('edit')).toBeUndefined()
    model[Symbol.dispose]()
  })

  test('derives an editable UID from the display name', () => {
    const model = new AgentEditorModel()
    model.initialize('new', {
      uid: '',
      displayName: '',
      avatarURL: '',
      role: 'Research Analyst'
    })

    model.setDisplayName('Research Analyst', true)
    expect(model.uid.value).toBe('research-analyst')

    model.setDisplayName('Research Director', true)
    expect(model.uid.value).toBe('research-director')

    model.setUID('research-lead')
    model.setDisplayName('Research Lead', true)
    expect(model.uid.value).toBe('research-lead')

    model.setDisplayName('Research Manager', true)
    expect(model.uid.value).toBe('research-lead')
    model[Symbol.dispose]()
  })

  test('normalizes generated UIDs and rejects an invalid manual UID', () => {
    expect(agentUIDFromDisplayName('  Caf\u00e9 & Research  ')).toBe('cafe-research')
    expect(agentUIDFromDisplayName('\u7814\u7a76\u5206\u6790\u5e08')).toBe('yanjiufenxishi')
    expect(agentUIDFromDisplayName('AI \u7814\u7a76 Analyst')).toBe('ai-yanjiu-analyst')
    expect(agentUIDFromDisplayName('\u0391\u03b8\u03ae\u03bd\u03b1 Research')).toBe('athina-research')
    expect(agentUIDError('')).toBe('uid_required')
    expect(agentUIDError('invalid uid')).toBe('uid_invalid')
    expect(agentUIDError('valid-agent')).toBeUndefined()

    const model = new AgentEditorModel()
    model.initialize('new', {
      uid: '',
      displayName: 'Invalid UID Agent',
      avatarURL: '',
      role: 'Research Analyst'
    })
    model.setUID('Invalid UID')
    expect(model.uid.value).toBe('invalid uid')
    expect(model.draftError('new')).toBe('uid_invalid')
    model[Symbol.dispose]()
  })
})
