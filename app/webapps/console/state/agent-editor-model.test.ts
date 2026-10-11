import { beforeAll, describe, expect, test } from 'bun:test'
import {
  AgentEditorModel,
  agentHandleError,
  agentHandleFromDisplayName,
  preloadTransliteration
} from './agent-editor-model'

// handle derivation upgrades from an ASCII-only fallback once the on-demand
// transliteration table loads; the assertions cover the loaded behavior.
beforeAll(() => preloadTransliteration())

describe('AgentEditorModel', () => {
  test('keeps edits during refetch and resets when the route selects another agent', () => {
    const model = new AgentEditorModel()

    model.initialize('agent:alpha', {
      handle: 'alpha',
      displayName: 'Alpha',
      avatarURL: '',
      ownerPrincipalUID: 'operator',
      groupMemoryDisclosureMode: 'strict' as const,
      workerProviderID: 'docker',
      role: 'Research Analyst'
    })
    expect(model.dirty.value).toBe(false)
    model.displayName.value = 'Edited Alpha'
    expect(model.dirty.value).toBe(true)
    model.initialize('agent:alpha', {
      handle: 'alpha',
      displayName: 'Refetched Alpha',
      avatarURL: '',
      ownerPrincipalUID: 'operator',
      groupMemoryDisclosureMode: 'strict' as const,
      workerProviderID: 'docker',
      role: 'Research Analyst'
    })

    expect(model.displayName.value).toBe('Edited Alpha')

    model.initialize('agent:beta', {
      handle: 'beta',
      displayName: 'Beta',
      avatarURL: '',
      ownerPrincipalUID: 'operator',
      groupMemoryDisclosureMode: 'strict' as const,
      workerProviderID: 'docker',
      role: 'Operator'
    })

    expect(model.handle.value).toBe('beta')
    expect(model.role.value).toBe('Operator')
    expect(model.validationError.value).toBeUndefined()
    expect(model.dirty.value).toBe(false)
    model[Symbol.dispose]()
  })

  test('reports the required display name, handle, role, and owner before submission', () => {
    const model = new AgentEditorModel()

    model.initialize('new', {
      handle: '',
      displayName: '',
      avatarURL: '',
      ownerPrincipalUID: '',
      groupMemoryDisclosureMode: 'strict' as const,
      workerProviderID: 'docker',
      role: ''
    })
    expect(model.draftError('new')).toBe('display_name_required')

    model.displayName.value = 'Research Analyst'
    expect(model.draftError('new')).toBe('handle_required')
    model.handle.value = 'research-analyst'
    model.role.value = '  '
    expect(model.draftError('new')).toBe('role_required')
    expect(model.draftError('edit')).toBe('role_required')

    model.role.value = 'Research Analyst'
    expect(model.draftError('new')).toBe('owner_required')
    expect(model.draftError('edit')).toBe('owner_required')

    model.ownerPrincipalUID.value = 'operator'
    expect(model.draftError('new')).toBeUndefined()
    model.workerProviderID.value = ''
    expect(model.draftError('new')).toBe('worker_provider_required')
    expect(model.draftError('edit')).toBeUndefined()
    model[Symbol.dispose]()
  })

  test('derives an editable handle from the display name', () => {
    const model = new AgentEditorModel()
    model.initialize('new', {
      handle: '',
      displayName: '',
      avatarURL: '',
      ownerPrincipalUID: 'operator',
      groupMemoryDisclosureMode: 'strict' as const,
      workerProviderID: 'docker',
      role: 'Research Analyst'
    })

    model.setDisplayName('Research Analyst', true)
    expect(model.handle.value).toBe('research-analyst')

    model.setDisplayName('Research Director', true)
    expect(model.handle.value).toBe('research-director')

    model.setHandle('research-lead')
    model.setDisplayName('Research Lead', true)
    expect(model.handle.value).toBe('research-lead')

    model.setDisplayName('Research Manager', true)
    expect(model.handle.value).toBe('research-lead')
    model[Symbol.dispose]()
  })

  test('normalizes generated handles and rejects an invalid manual handle', () => {
    expect(agentHandleFromDisplayName('  Caf\u00e9 & Research  ')).toBe('cafe-research')
    expect(agentHandleFromDisplayName('\u7814\u7a76\u5206\u6790\u5e08')).toBe('yanjiufenxishi')
    expect(agentHandleFromDisplayName('AI \u7814\u7a76 Analyst')).toBe('ai-yanjiu-analyst')
    expect(agentHandleFromDisplayName('\u0391\u03b8\u03ae\u03bd\u03b1 Research')).toBe('athina-research')
    expect(agentHandleError('')).toBe('handle_required')
    expect(agentHandleError('invalid handle')).toBe('handle_invalid')
    expect(agentHandleError('valid-agent')).toBeUndefined()

    const model = new AgentEditorModel()
    model.initialize('new', {
      handle: '',
      displayName: 'Invalid handle Agent',
      avatarURL: '',
      ownerPrincipalUID: 'operator',
      groupMemoryDisclosureMode: 'strict' as const,
      workerProviderID: 'docker',
      role: 'Research Analyst'
    })
    model.setHandle('Invalid handle')
    expect(model.handle.value).toBe('invalid handle')
    expect(model.draftError('new')).toBe('handle_invalid')
    model[Symbol.dispose]()
  })
})
