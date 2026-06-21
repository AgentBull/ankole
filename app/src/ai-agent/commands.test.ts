import { describe, expect, it } from 'bun:test'
import { commandFeedbackIntent } from './commands'

describe('commandFeedbackIntent', () => {
  const base = { commandEventId: 'evt-1', providerRoomId: 'room', providerThreadId: 'thread', text: 'Stopped.' }

  // The load-bearing invariant: surface + caps pick the operation/payload
  // (divider vs card vs plain post), but the outboundKey stays identical across
  // all four so idempotency/recovery is unaffected when the surface flips.
  it('renders command feedback for DM, group, and fallback surfaces without changing the recovery key', () => {
    const post = commandFeedbackIntent(base)
    const divider = commandFeedbackIntent({
      ...base,
      surface: 'dm',
      caps: { dividerCapable: true, cardCapable: false }
    })
    const card = commandFeedbackIntent({ ...base, surface: 'group', caps: { dividerCapable: true, cardCapable: true } })
    const groupWithoutCards = commandFeedbackIntent({
      ...base,
      surface: 'group',
      caps: { dividerCapable: true, cardCapable: false }
    })

    expect([post.outboundKey, divider.outboundKey, card.outboundKey, groupWithoutCards.outboundKey]).toEqual(
      Array(4).fill('ai-agent-command-feedback:evt-1:final')
    )
    expect(post).toMatchObject({ operation: 'post', finalPayload: { text: 'Stopped.' } })
    expect(divider).toMatchObject({
      operation: 'divider',
      finalPayload: { kind: 'control_notice', text: 'Stopped.', fallbackText: 'Stopped.' }
    })
    expect(card.finalPayload).toMatchObject({
      kind: 'interactive_output',
      output: {
        version: 'bullx.interactive_output.v1',
        content: { body: 'Stopped.', format: 'plain' },
        fallbackText: 'Stopped.'
      }
    })
    expect(groupWithoutCards).toMatchObject({ operation: 'post', finalPayload: { text: 'Stopped.' } })
  })
})
