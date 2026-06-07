import { describe, expect, it } from 'bun:test'
import { AiAgentClarifyRegistry, type ClarifyResolution } from './clarify-registry'

function register(registry: AiAgentClarifyRegistry, conversationId: string, onResolve: (r: ClarifyResolution) => void) {
  registry.register({
    conversationId,
    toolCallId: 'tc',
    leaseId: 'lease',
    question: 'q',
    choices: [],
    awaitingText: true,
    askedOutboundKey: 'k',
    resolve: onResolve,
    timeoutTimer: setTimeout(() => undefined, 1_000_000),
    heartbeatTimer: setInterval(() => undefined, 1_000_000)
  })
}

describe('AiAgentClarifyRegistry', () => {
  it('registers, reports pending, and resolves exactly once', () => {
    const registry = new AiAgentClarifyRegistry()
    let resolved: ClarifyResolution | undefined
    register(registry, 'c1', r => {
      resolved = r
    })

    expect(registry.has('c1')).toBe(true)
    expect(registry.resolveByConversation('c1', { kind: 'answer', text: 'x', choiceIndex: 0 })).toBe(true)
    expect(resolved).toEqual({ kind: 'answer', text: 'x', choiceIndex: 0 })
    expect(registry.has('c1')).toBe(false)
    // second resolve is a no-op
    expect(registry.resolveByConversation('c1', { kind: 'timeout' })).toBe(false)
  })

  it('tryReserve blocks a second concurrent claim until released', () => {
    const registry = new AiAgentClarifyRegistry()
    expect(registry.tryReserve('c1')).toBe(true)
    expect(registry.tryReserve('c1')).toBe(false)
    registry.releaseReservation('c1')
    expect(registry.tryReserve('c1')).toBe(true)
  })

  it('register throws when a clarify is already pending', () => {
    const registry = new AiAgentClarifyRegistry()
    register(registry, 'c1', () => undefined)
    expect(() => register(registry, 'c1', () => undefined)).toThrow()
    registry.resolveByConversation('c1', { kind: 'aborted' })
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
