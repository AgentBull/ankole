import { describe, expect, it } from 'bun:test'
import {
  larkCompactNoticeCard,
  larkChannelLoggerFromChat,
  larkDividerOriginalTextFromPayload,
  larkDividerPayload,
  larkDividerPayloadFromMessage,
  larkDividerTextFromPayload,
  larkSdkLogData,
  larkSdkLogMessage,
  normalizeLarkDividerText
} from './lark-helpers'

describe('larkDividerPayloadFromMessage', () => {
  it('builds a Feishu system divider from a divider-operation postable', () => {
    const payload = larkDividerPayloadFromMessage({
      kind: 'control_notice',
      text: 'New conversation started.',
      type: 'divider'
    })
    expect(payload).toEqual({
      type: 'divider',
      params: { divider_text: { text: 'New conversation...' } },
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

describe('lark SDK logging', () => {
  it('keeps object-only SDK args structured with a stable message', () => {
    const first = { code: 99991663, msg: 'server response error' }
    const second = { requestId: 'req-1' }

    expect(larkSdkLogMessage([first, second])).toBe('Lark SDK log')
    expect(larkSdkLogData([first, second])).toEqual({ args: [first, second] })
  })

  it('does not stringify channel SDK object logs through adapter logger', () => {
    const logs: any[] = []
    const logger = {
      error(data: unknown, message: string) {
        logs.push({ data, message })
      }
    }
    const chat = {
      getLogger: () => logger
    }
    const first = { code: 99991663, msg: 'server response error' }
    const second = { requestId: 'req-1' }

    larkChannelLoggerFromChat(chat).error(first, second)

    expect(logs).toEqual([{ data: { args: [first, second] }, message: 'Lark SDK log' }])
    expect(JSON.stringify(logs)).not.toContain('[object Object]')
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

  it('extracts divider text for card fallback rendering', () => {
    expect(larkDividerTextFromPayload(larkDividerPayload('hi'))).toBe('hi')
  })

  it('keeps divider text within the Feishu system-message limit', () => {
    expect(normalizeLarkDividerText('New conversation started.')).toEqual({
      text: 'New conversation...',
      truncated: true
    })
    expect(normalizeLarkDividerText('新会话已经开始请继续处理')).toEqual({
      text: '新会话已经开始请...',
      truncated: true
    })
    expect(normalizeLarkDividerText('ＡＢＣＤＥＦＧＨＩＪＫ')).toEqual({
      text: 'ＡＢＣＤＥＦＧＨ...',
      truncated: true
    })
    expect(normalizeLarkDividerText('status 🚀🚀🚀🚀🚀🚀🚀')).toEqual({
      text: 'status 🚀🚀🚀🚀🚀...',
      truncated: true
    })

    const payload = larkDividerPayload('New conversation started.')
    expect(larkDividerTextFromPayload(payload)).toBe('New conversation...')
    expect(larkDividerOriginalTextFromPayload(payload)).toBe('New conversation started.')
    expect(JSON.stringify(payload)).not.toContain('New conversation started.')
  })
})
