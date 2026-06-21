// Covers the sparse-injection rules: time appears only after a long enough gap, room/speaker only when
// they change versus the prior message, and the frozen `injected` flags drive what the rendered
// `<message_context>` block actually shows. Second test pins that trusted introspection trigger fields
// are always rendered and that the prefix is woven into the user message without mutating the stored one.
import { describe, expect, it } from 'bun:test'
import { loadTestEnvFiles } from '@/common/tests/load-test-env'

await loadTestEnvFiles()

const { appendMessageContextHistory, buildMessageContextMetadata, renderMessageWithContext } =
  await import('./message-context')
const { createUserMessage } = await import('./core')

describe('AIAgent message context', () => {
  it('injects time sparsely and renders group speaker only when the previous actor changes', () => {
    const history: Array<{ metadata: Record<string, any> }> = []
    const room = { id: 'room-1', isDM: false, name: 'Ops' }
    const alice = { userId: 'alice', fullName: 'Alice' }
    const timezone = 'Asia/Shanghai'

    const first = buildMessageContextMetadata(
      { actor: alice, room, sentAt: new Date('2026-06-09T01:00:00.000Z'), timezone },
      history as any
    )
    expect((first as any).time.injected).toBe(false)
    expect((first as any).room.injected).toBe(true)
    expect((first as any).actor.injected).toBe(true)
    appendMessageContextHistory(history as any, { message_context: first } as any)

    const sameSpeaker = buildMessageContextMetadata(
      { actor: alice, room, sentAt: new Date('2026-06-09T01:30:00.000Z'), timezone },
      history as any
    )
    expect((sameSpeaker as any).time.injected).toBe(false)
    expect((sameSpeaker as any).room.injected).toBe(false)
    expect((sameSpeaker as any).actor.injected).toBe(false)
    appendMessageContextHistory(history as any, { message_context: sameSpeaker } as any)

    const bob = buildMessageContextMetadata(
      { actor: { userId: 'bob', fullName: 'Bob' }, room, sentAt: new Date('2026-06-09T01:40:00.000Z'), timezone },
      history as any
    )
    expect((bob as any).time.injected).toBe(false)
    expect((bob as any).actor.injected).toBe(true)
    appendMessageContextHistory(history as any, { message_context: bob } as any)

    // >1h after the last timestamped message (01:40 → 02:45), so time is re-injected; speaker is back to
    // Alice after Bob, so the actor is re-injected too.
    const later = buildMessageContextMetadata(
      { actor: alice, room, sentAt: new Date('2026-06-09T02:45:00.000Z'), timezone },
      history as any
    )
    expect((later as any).time.injected).toBe(true)
    expect((later as any).actor.injected).toBe(true)

    // An actor-less turn (no `actor`, e.g. a system/ambient message) is appended to history. The next
    // Alice turn still re-injects the actor: the prior message had no actor to match against, so the
    // change-detection treats Alice as newly present rather than carrying forward the last named speaker.
    appendMessageContextHistory(
      history as any,
      {
        message_context: buildMessageContextMetadata(
          { room, sentAt: new Date('2026-06-09T02:50:00.000Z'), timezone },
          history as any
        )
      } as any
    )
    const afterUnownedTurn = buildMessageContextMetadata(
      { actor: alice, room, sentAt: new Date('2026-06-09T02:55:00.000Z'), timezone },
      history as any
    )
    expect((afterUnownedTurn as any).actor.injected).toBe(true)
  })

  it('renders trusted introspection trigger fields inside message context', () => {
    const context = buildMessageContextMetadata(
      {
        sentAt: new Date('2026-06-09T01:15:42.123Z'),
        speaker: 'Agent <One>',
        speakerRole: 'agent',
        speakerTrigger: 'introspection',
        think: 'BullX determined that Agent <One> should respond based on <chat_segment>.',
        timezone: 'Asia/Shanghai'
      },
      []
    )
    const message = createUserMessage('please help')
    const rendered = renderMessageWithContext(message, { message_context: context } as any) as {
      content: Array<{ text?: string; type: string }>
    }

    const text = rendered.content[0]!.text ?? ''
    expect(text).toContain('<message_context>')
    // No prior history was passed, so time stays un-injected (no gap to report) and there is no room —
    // only the always-trusted introspection speaker/think fields render. These negatives guard against
    // the renderer leaking the raw timestamp or a room line that was never marked injected.
    expect(text).not.toContain('sent_at: 2026-06-09 09:15:42 (Asia/Shanghai)')
    expect(text).not.toContain('2026-06-09T01:15:42.123Z')
    expect(text).not.toContain('room: group chat "Ops"')
    expect(text).toContain('speaker: Agent <One>')
    expect(text).toContain('speaker_role: agent')
    expect(text).toContain('speaker_trigger: introspection')
    expect(text).toContain('think: BullX determined that Agent <One> should respond based on <chat_segment>.')
    expect(text).not.toContain('<ambient_references')
    expect(text).not.toContain('<ambient_reference_context>')
    expect(text).toContain('please help')
    expect((message.content as Array<{ text: string }>)[0]!.text).toBe('please help')
  })
})
