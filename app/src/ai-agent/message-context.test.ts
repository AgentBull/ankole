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
    const timezone = 'Asia/Shanghai'

    const first = buildMessageContextMetadata(
      { actor: alice, room, sentAt: new Date('2026-06-09T01:00:00.000Z'), timezone },
      history as any
    )
    expect((first as any).time.injected).toBe(true)
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

    const bob = buildMessageContextMetadata(
      { actor: { userId: 'bob', fullName: 'Bob' }, room, sentAt: new Date('2026-06-09T01:40:00.000Z'), timezone },
      history as any
    )
    expect((bob as any).time.injected).toBe(false)
    expect((bob as any).actor.injected).toBe(true)

    const later = buildMessageContextMetadata(
      { actor: alice, room, sentAt: new Date('2026-06-09T02:05:00.000Z'), timezone },
      history as any
    )
    expect((later as any).time.injected).toBe(true)
  })

  it('renders message and ambient references as scoped evidence inside message context', () => {
    const context = buildMessageContextMetadata(
      {
        actor: { userId: 'alice', fullName: 'Alice' },
        ambientReferences: [
          {
            actorDisplayName: 'Bob "Ops"',
            sentAt: '2026-06-09T01:10:00.000Z',
            text: 'deploy is stuck <please help>'
          }
        ],
        room: { id: 'room-1', isDM: false, name: 'Ops' },
        sentAt: new Date('2026-06-09T01:15:42.123Z'),
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
    expect(text).toContain('sent_at: 2026-06-09 09:15:42 (Asia/Shanghai)')
    expect(text).not.toContain('2026-06-09T01:15:00.000Z')
    expect(text).toContain('room: group chat "Ops"')
    expect(text).toContain('speaker: Alice')
    expect(text).toContain(
      '<ambient_references purpose="evidence_for_intervention" reply_policy="do_not_answer_directly">'
    )
    expect(text).toContain('speaker="Bob &quot;Ops&quot;"')
    expect(text).toContain('sent_at="2026-06-09 09:10:00 (Asia/Shanghai)"')
    expect(text).toContain('deploy is stuck &lt;please help&gt;')
    expect(text).toContain('Do not answer every ambient reference line.')
    expect(text).not.toContain('<ambient_reference_context>')
    expect(text.indexOf('<ambient_references')).toBeGreaterThan(text.indexOf('<message_context>'))
    expect(text.indexOf('</ambient_references>')).toBeLessThan(text.indexOf('</message_context>'))
    expect(text).toContain('please help')
    expect((message.content as Array<{ text: string }>)[0]!.text).toBe('please help')
  })
})
