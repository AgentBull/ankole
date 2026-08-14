import { describe, expect, test } from 'bun:test'
import { automationJobAgentUID, automationJobDetailParams, automationJobScopeParams } from './automation-jobs'

describe('Automation Job detail ownership', () => {
  test('uses the row owner or the selected Agent for the Agent-scoped detail route', () => {
    const jobs = [{ id: 1000, agent_uid: 'agent-a' }]

    expect(automationJobAgentUID(jobs, 1000, '')).toBe('agent-a')
    expect(automationJobAgentUID(jobs, 2000, 'agent-b')).toBe('agent-b')
    expect(automationJobAgentUID(jobs, 2000, '')).toBe('')
  })

  test('puts the owning Agent in a detail URL so the link does not depend on the current list page', () => {
    const selected = automationJobDetailParams(new URLSearchParams('include_finished=true'), {
      id: 1000,
      agent_uid: 'agent-a'
    })

    expect(selected.toString()).toBe('include_finished=true&agent=agent-a&job=1000')
    expect(automationJobAgentUID([], 1000, selected.get('agent') ?? '')).toBe('agent-a')
  })

  test('closes an open detail when the Agent filter changes', () => {
    const selected = automationJobScopeParams(new URLSearchParams('agent=agent-a&job=1000'), 'agent-b')
    expect(selected.toString()).toBe('agent=agent-b')

    const allAgents = automationJobScopeParams(new URLSearchParams('agent=agent-a&job=1000'), '')
    expect(allAgents.toString()).toBe('')
  })
})
