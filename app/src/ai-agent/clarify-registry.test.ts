import { describe, expect, it } from 'bun:test'
import { AiAgentClarifyRegistry, type ClarifyResolution } from './clarify-registry'

function register(
  registry: AiAgentClarifyRegistry,
  conversationId: string,
  onResolve: (r: ClarifyResolution) => void,
  providerRoomId = `room-${conversationId}`
) {
  registry.register({
    conversationId,
    toolCallId: 'tc',
    leaseId: 'lease',
    question: 'q',
    choices: [],
    awaitingText: true,
    askedOutboundKey: 'k',
    providerRoomId,
    providerThreadId: providerRoomId,
    cardCapable: false,
    resolve: onResolve,
    timeoutTimer: setTimeout(() => undefined, 1_000_000),
    heartbeatTimer: setInterval(() => undefined, 1_000_000)
  })
}

describe('AiAgentClarifyRegistry', () => {
  it('guards one pending clarify from reservation through room-scoped resolution', () => {
    const registry = new AiAgentClarifyRegistry()

    expect(registry.tryReserve('c1')).toBe(true)
    expect(registry.tryReserve('c1')).toBe(false)
    registry.releaseReservation('c1')
    expect(registry.tryReserve('c1')).toBe(true)
    registry.releaseReservation('c1')

    let resolved: ClarifyResolution | undefined
    register(
      registry,
      'c1',
      r => {
        resolved = r
      },
      'room-a'
    )

    expect(registry.has('c1')).toBe(true)
    expect(registry.pendingConversationForRoom('room-a')).toBe('c1')
    expect(registry.pendingConversationForRoom('room-b')).toBeUndefined()
    expect(() => register(registry, 'c1', () => undefined)).toThrow()

    expect(registry.resolveByConversation('c1', { kind: 'answer', text: 'x', choiceIndex: 0 })).toBe(true)
    expect(resolved).toEqual({ kind: 'answer', text: 'x', choiceIndex: 0 })
    expect(registry.has('c1')).toBe(false)
    expect(registry.pendingConversationForRoom('room-a')).toBeUndefined()
    // second resolve is a no-op
    expect(registry.resolveByConversation('c1', { kind: 'timeout' })).toBe(false)
  })

  it('abort resolves with the given reason', () => {
    const registry = new AiAgentClarifyRegistry()
    let resolved: ClarifyResolution | undefined
    register(registry, 'c1', r => {
      resolved = r
    })
    expect(registry.abort('c1', 'superseded')).toBe(true)
    expect(resolved).toEqual({ kind: 'superseded' })
  })
})
