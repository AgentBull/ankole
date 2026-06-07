import { describe, expect, it } from 'bun:test'
import { commandFeedbackIntent, controlNoticeOperation } from './commands'

describe('controlNoticeOperation', () => {
  it('DM with divider capability -> divider', () => {
    expect(controlNoticeOperation('dm', { dividerCapable: true, cardCapable: true })).toBe('divider')
  })

  it('group with card capability -> card', () => {
    expect(controlNoticeOperation('group', { dividerCapable: true, cardCapable: true })).toBe('card')
  })

  it('falls back to post when the surface capability is missing', () => {
    expect(controlNoticeOperation('dm', { dividerCapable: false, cardCapable: true })).toBe('post')
    expect(controlNoticeOperation('group', { dividerCapable: true, cardCapable: false })).toBe('post')
  })
})

describe('commandFeedbackIntent', () => {
  const base = { commandEventId: 'evt-1', providerRoomId: 'room', providerThreadId: 'thread', text: 'Stopped.' }

  it('keeps a stable outboundKey regardless of operation', () => {
    const post = commandFeedbackIntent(base)
    const divider = commandFeedbackIntent({ ...base, surface: 'dm', caps: { dividerCapable: true, cardCapable: false } })
    expect(post.outboundKey).toBe(divider.outboundKey)
  })

  it('DM divider carries a control_notice payload with text', () => {
    const intent = commandFeedbackIntent({ ...base, surface: 'dm', caps: { dividerCapable: true, cardCapable: false } })
    expect(intent.operation).toBe('divider')
    expect(intent.finalPayload).toMatchObject({ kind: 'control_notice', text: 'Stopped.', fallbackText: 'Stopped.' })
  })

  it('no surface/caps stays a plain post', () => {
    const intent = commandFeedbackIntent(base)
    expect(intent.operation).toBe('post')
    expect(intent.finalPayload).toEqual({ text: 'Stopped.' })
  })
})
