import { describe, expect, it } from 'bun:test'
import { larkCompactNoticeCard, larkDividerPayload, larkDividerPayloadFromMessage } from './lark-helpers'

describe('larkDividerPayloadFromMessage', () => {
  it('builds a Feishu system divider from a divider-operation postable', () => {
    const payload = larkDividerPayloadFromMessage({
      kind: 'control_notice',
      text: 'New conversation started.',
      type: 'divider'
    })
    expect(payload).toEqual({
      type: 'divider',
      params: { divider_text: { text: 'New conversation started.' } },
      options: { need_rollup: true }
    })
  })

  it('returns undefined for a control_notice card payload (no type:divider)', () => {
    // The 'card' operation keeps kind only -> must fall through to the card path.
    expect(larkDividerPayloadFromMessage({ kind: 'control_notice', text: 'x' })).toBeUndefined()
  })

  it('returns undefined for ordinary messages', () => {
    expect(larkDividerPayloadFromMessage({ text: 'hello' })).toBeUndefined()
    expect(larkDividerPayloadFromMessage('hello')).toBeUndefined()
  })
})

describe('larkCompactNoticeCard', () => {
  it('renders grey notation text without a divider by default', () => {
    const card = larkCompactNoticeCard('Stopped.') as any
    expect(card.schema).toBe('2.0')
    expect(card.body.elements).toHaveLength(1)
    expect(card.body.elements[0]).toMatchObject({
      tag: 'div',
      text: { tag: 'plain_text', content: 'Stopped.', text_color: 'grey', text_size: 'notation' }
    })
  })

  it('prepends an hr when divider is requested', () => {
    const card = larkCompactNoticeCard('Stopped.', { divider: true }) as any
    expect(card.body.elements[0].tag).toBe('hr')
    expect(card.body.elements[1].text.content).toBe('Stopped.')
  })
})

describe('larkDividerPayload', () => {
  it('wraps text in the divider params shape', () => {
    expect(larkDividerPayload('hi')).toEqual({
      type: 'divider',
      params: { divider_text: { text: 'hi' } },
      options: { need_rollup: true }
    })
  })
})
