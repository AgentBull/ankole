import { describe, expect, test } from 'bun:test'
import { AgentEditorModel, agentUIDError } from './agent-editor-model'

describe('AgentEditorModel', () => {
  test('reports the required display name, uid, role, and owner before submission', () => {
    const model = new AgentEditorModel()

    model.initialize('new', {
      uid: '',
      displayName: '',
      avatarURL: '',
      ownerPrincipalUID: '',
      groupMemoryDisclosureMode: 'strict' as const,
      workerProviderID: 'docker',
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
    expect(model.draftError('new')).toBe('owner_required')
    expect(model.draftError('edit')).toBe('owner_required')

    model.ownerPrincipalUID.value = 'operator'
    expect(model.draftError('new')).toBeUndefined()
    model.workerProviderID.value = ''
    expect(model.draftError('new')).toBe('worker_provider_required')
    expect(model.draftError('edit')).toBeUndefined()
    model[Symbol.dispose]()
  })

  test('requires an explicit uid independent of the display name', () => {
    const model = new AgentEditorModel()
    model.initialize('new', {
      uid: '',
      displayName: '',
      avatarURL: '',
      ownerPrincipalUID: 'operator',
      groupMemoryDisclosureMode: 'strict' as const,
      workerProviderID: 'docker',
      role: 'Research Analyst'
    })

    model.setDisplayName('Research Analyst')
    expect(model.uid.value).toBe('')

    model.setDisplayName('Research Director')
    expect(model.uid.value).toBe('')

    model.setUID('research-lead')
    model.setDisplayName('Research Lead')
    expect(model.uid.value).toBe('research-lead')

    model.setDisplayName('Research Manager')
    expect(model.uid.value).toBe('research-lead')
    model[Symbol.dispose]()
  })

  test('accepts email-like uids and rejects invalid or overlong names', () => {
    expect(agentUIDError('')).toBe('uid_required')
    expect(agentUIDError('invalid uid')).toBe('uid_invalid')
    expect(agentUIDError('valid-agent')).toBeUndefined()
    expect(agentUIDError('research+daily@example.test')).toBeUndefined()
    expect(agentUIDError('a'.repeat(97))).toBe('uid_invalid')

    const model = new AgentEditorModel()
    model.initialize('new', {
      uid: '',
      displayName: 'Invalid uid Agent',
      avatarURL: '',
      ownerPrincipalUID: 'operator',
      groupMemoryDisclosureMode: 'strict' as const,
      workerProviderID: 'docker',
      role: 'Research Analyst'
    })
    model.setUID('Invalid uid')
    expect(model.uid.value).toBe('invalid uid')
    expect(model.draftError('new')).toBe('uid_invalid')
    model[Symbol.dispose]()
  })
})
