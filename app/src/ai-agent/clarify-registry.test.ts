import { describe, expect, it } from 'bun:test'
import { AiAgentClarifyRegistry, type ClarifyEntry } from './clarify-registry'

function entry(conversationId: string, overrides: Partial<ClarifyEntry> = {}): ClarifyEntry {
  return {
    conversationId,
    toolCallId: 'tc-1',
    question: 'A or B?',
    choices: ['A', 'B'],
    askedOutboundKey: `ai-agent-clarify:${conversationId}:tc-1`,
    providerRoomId: 'room-1',
    providerThreadId: 'room-1:thread',
    cardCapable: true,
    ...overrides
  }
}

describe('AiAgentClarifyRegistry', () => {
  it('take returns the entry once; later takes find nothing', () => {
    const registry = new AiAgentClarifyRegistry()
    registry.set(entry('c1'))
    expect(registry.has('c1')).toBe(true)
    expect(registry.pendingConversationForRoom('room-1')).toBe('c1')

    const taken = registry.take('c1')
    expect(taken?.question).toBe('A or B?')
    expect(registry.has('c1')).toBe(false)
    expect(registry.pendingConversationForRoom('room-1')).toBeUndefined()
    expect(registry.take('c1')).toBeUndefined()
  })

  it('a newer ask replaces the previous unanswered one', () => {
    const registry = new AiAgentClarifyRegistry()
    registry.set(entry('c1', { toolCallId: 'tc-1', question: 'old?' }))
    registry.set(entry('c1', { toolCallId: 'tc-2', question: 'new?' }))
    expect(registry.get('c1')?.question).toBe('new?')
    expect(registry.pendingConversationForRoom('room-1')).toBe('c1')
    registry.clear('c1')
    expect(registry.pendingConversationForRoom('room-1')).toBeUndefined()
  })

  it('expires the gate after the ttl', async () => {
    const registry = new AiAgentClarifyRegistry()
    registry.set(entry('c1'), 30)
    expect(registry.has('c1')).toBe(true)
    await Bun.sleep(80)
    expect(registry.has('c1')).toBe(false)
    expect(registry.pendingConversationForRoom('room-1')).toBeUndefined()
  })

  it('clear is idempotent and scoped to the conversation owning the room gate', () => {
    const registry = new AiAgentClarifyRegistry()
    registry.set(entry('c1', { providerRoomId: 'room-1' }))
    registry.set(entry('c2', { providerRoomId: 'room-2' }))
    expect(registry.clear('c1')).toBe(true)
    expect(registry.clear('c1')).toBe(false)
    expect(registry.pendingConversationForRoom('room-2')).toBe('c2')
  })
})
