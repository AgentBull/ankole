import 'reflect-metadata'
import { describe, expect, it } from 'bun:test'
import { loadTestEnvFiles } from '@/common/tests/load-test-env'

await loadTestEnvFiles()

const { appendMessageContextHistory, buildMessageContextMetadata, renderMessageWithContext } =
  await import('./message-context')
const { createUserMessage } = await import('./core')

describe('AIAgent message context', () => {
  it('injects time sparsely and repeats group speaker only when it changes', () => {
    const history: Array<{ metadata: Record<string, any> }> = []
    const room = { id: 'room-1', isDM: false, name: 'Ops' }
    const alice = { userId: 'alice', fullName: 'Alice' }

    const first = buildMessageContextMetadata(
      { actor: alice, room, sentAt: new Date('2026-06-09T01:00:00.000Z') },
      history as any
    )
    expect((first as any).time.injected).toBe(true)
    expect((first as any).room.injected).toBe(true)
    expect((first as any).actor.injected).toBe(true)
    appendMessageContextHistory(history as any, { message_context: first } as any)

    const sameSpeaker = buildMessageContextMetadata(
      { actor: alice, room, sentAt: new Date('2026-06-09T01:30:00.000Z') },
      history as any
    )
    expect((sameSpeaker as any).time.injected).toBe(false)
    expect((sameSpeaker as any).room.injected).toBe(false)
    expect((sameSpeaker as any).actor.injected).toBe(false)

    const bob = buildMessageContextMetadata(
      { actor: { userId: 'bob', fullName: 'Bob' }, room, sentAt: new Date('2026-06-09T01:40:00.000Z') },
      history as any
    )
    expect((bob as any).time.injected).toBe(false)
    expect((bob as any).actor.injected).toBe(true)

    const later = buildMessageContextMetadata(
      { actor: alice, room, sentAt: new Date('2026-06-09T02:05:00.000Z') },
      history as any
    )
    expect((later as any).time.injected).toBe(true)
  })

  it('renders message and ambient reference context as a user message prefix', () => {
    const context = buildMessageContextMetadata(
      {
        actor: { userId: 'alice', fullName: 'Alice' },
        ambientReferences: [{ actorDisplayName: 'Bob', sentAt: '2026-06-09T01:10:00.000Z', text: 'deploy is stuck' }],
        room: { id: 'room-1', isDM: false, name: 'Ops' },
        sentAt: new Date('2026-06-09T01:15:00.000Z')
      },
      []
    )
    const message = createUserMessage('please help')
    const rendered = renderMessageWithContext(message, { message_context: context } as any) as {
      content: Array<{ text?: string; type: string }>
    }

    const text = rendered.content[0]!.text ?? ''
    expect(text).toContain('<message_context>')
    expect(text).toContain('room: group chat "Ops"')
    expect(text).toContain('speaker: Alice')
    expect(text).toContain('<ambient_reference_context>')
    expect(text).toContain('Bob: deploy is stuck')
    expect(text).toContain('please help')
    expect((message.content as Array<{ text: string }>)[0]!.text).toBe('please help')
  })
})
