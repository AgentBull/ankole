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

// Guards the registry invariants the answer-side flow leans on: take is
// once-only (first answer wins), the newest ask replaces an older one, the TTL
// drops the group-reply gate, and clear stays scoped to its own room.
describe('AiAgentClarifyRegistry', () => {
  // take() is the single-consumer handoff: the first caller gets the entry and
  // the room gate clears, so a second answer cannot re-trigger.
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

  // After the TTL the entry and its room gate are gone, so a much later reply is
  // treated as ordinary chatter rather than captured as an answer.
  it('expires the gate after the ttl', async () => {
    const registry = new AiAgentClarifyRegistry()
    registry.set(entry('c1'), 30)
    expect(registry.has('c1')).toBe(true)
    await Bun.sleep(80)
    expect(registry.has('c1')).toBe(false)
    expect(registry.pendingConversationForRoom('room-1')).toBeUndefined()
  })

  // Clearing one conversation must not evict another conversation's gate in a
  // different room — the room index is keyed per room, not global.
  it('clear is idempotent and scoped to the conversation owning the room gate', () => {
    const registry = new AiAgentClarifyRegistry()
    registry.set(entry('c1', { providerRoomId: 'room-1' }))
    registry.set(entry('c2', { providerRoomId: 'room-2' }))
    expect(registry.clear('c1')).toBe(true)
    expect(registry.clear('c1')).toBe(false)
    expect(registry.pendingConversationForRoom('room-2')).toBe('c2')
  })
})
