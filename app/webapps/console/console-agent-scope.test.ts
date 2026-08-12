import { describe, expect, test } from 'bun:test'
import { resolveAgentUID } from './console-agent-scope'

describe('resolveAgentUID', () => {
  test('keeps a known request, empties an unknown one, and defaults to the first agent', () => {
    const agents = [{ uid: 'agent-a' }, { uid: 'agent-b' }]

    expect(resolveAgentUID(agents, 'agent-b')).toBe('agent-b')
    expect(resolveAgentUID(agents, 'missing-agent')).toBe('')
    expect(resolveAgentUID(agents, '')).toBe('agent-a')
    expect(resolveAgentUID([], '')).toBe('')
    expect(resolveAgentUID([], 'missing-agent')).toBe('')
  })
})
