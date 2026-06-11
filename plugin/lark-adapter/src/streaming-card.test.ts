import { describe, expect, it } from 'bun:test'
import type { SharedLarkConnection } from './connection'
import { createLarkStreamingCardSession } from './streaming-card'

interface RecordedCall {
  kind:
    | 'card.create'
    | 'card.settings'
    | 'cardElement.update'
    | 'cardElement.content'
    | 'message.create'
    | 'message.reply'
  data?: any
  path?: any
}

function fakeConnection(calls: RecordedCall[]): SharedLarkConnection {
  const rawClient = {
    cardkit: {
      v1: {
        card: {
          create: async (payload: any) => {
            calls.push({ kind: 'card.create', data: payload.data })
            return { code: 0, data: { card_id: 'card-1' } }
          },
          settings: async (payload: any) => {
            calls.push({ kind: 'card.settings', data: payload.data, path: payload.path })
            return { code: 0, data: {} }
          }
        },
        cardElement: {
          update: async (payload: any) => {
            calls.push({ kind: 'cardElement.update', data: payload.data, path: payload.path })
            return { code: 0, data: {} }
          },
          content: async (payload: any) => {
            calls.push({ kind: 'cardElement.content', data: payload.data, path: payload.path })
            return { code: 0, data: {} }
          }
        }
      }
    },
    im: {
      v1: {
        message: {
          create: async (payload: any) => {
            calls.push({ kind: 'message.create', data: payload.data })
            return { code: 0, data: { message_id: 'msg-1' } }
          },
          reply: async (payload: any) => {
            calls.push({ kind: 'message.reply', data: payload.data, path: payload.path })
            return { code: 0, data: { message_id: 'msg-2' } }
          }
        }
      }
    }
  }
  return { rawClient } as unknown as SharedLarkConnection
}

describe('LarkStreamingCardSession', () => {
  it('creates a CardKit card, sends an interactive message, replaces-element then patches-content with rising sequence, and closes streaming', async () => {
    const calls: RecordedCall[] = []
    const session = await createLarkStreamingCardSession(fakeConnection(calls), {
      chatId: 'oc_x',
      intervalMs: 0,
      bufferThreshold: 1
    })

    expect(session.cardId).toBe('card-1')
    expect(session.messageId).toBe('msg-1')

    const created = calls.find(c => c.kind === 'card.create')
    expect(created?.data?.type).toBe('card_json')

    const sent = calls.find(c => c.kind === 'message.create')
    expect(sent?.data?.msg_type).toBe('interactive')
    expect(JSON.parse(sent?.data?.content)).toEqual({ type: 'card', data: { card_id: 'card-1' } })

    await session.update('hi')
    await session.update('hi there')
    const finish = await session.finish('hi there', 'completed')

    // first content write replaces the placeholder element with a full markdown element
    const replace = calls.find(c => c.kind === 'cardElement.update')
    expect(replace?.path).toEqual({ card_id: 'card-1', element_id: 'content' })
    expect(JSON.parse(replace!.data.element)).toMatchObject({ tag: 'markdown', element_id: 'content', content: 'hi' })

    // subsequent writes patch element content only
    const patch = calls.find(c => c.kind === 'cardElement.content')
    expect(patch?.path).toEqual({ card_id: 'card-1', element_id: 'content' })
    expect(patch!.data.content).toBe(' there')

    // finish closes streaming mode
    const settings = calls.find(c => c.kind === 'card.settings')
    expect(settings?.path).toEqual({ card_id: 'card-1' })
    expect(JSON.parse(settings!.data.settings).config.streaming_mode).toBe(false)

    // sequences strictly increase across element/settings writes
    const seqs = calls.filter(c => typeof c.data?.sequence === 'number').map(c => c.data.sequence as number)
    expect(seqs.length).toBeGreaterThanOrEqual(3)
    for (let i = 1; i < seqs.length; i++) expect(seqs[i]!).toBeGreaterThan(seqs[i - 1]!)
    expect(finish).toMatchObject({ delivered: true, finalTextConfirmed: true })
  })

  it('degrades silently and never throws when CardKit calls fail', async () => {
    const failing = {
      rawClient: {
        cardkit: {
          v1: {
            card: {
              create: async () => {
                throw new Error('cardkit down')
              },
              settings: async () => ({ code: 0, data: {} })
            },
            cardElement: { update: async () => ({ code: 0 }), content: async () => ({ code: 0 }) }
          }
        },
        im: { v1: { message: { create: async () => ({ code: 0, data: { message_id: 'm' } }) } } }
      }
    } as unknown as SharedLarkConnection

    const session = await createLarkStreamingCardSession(failing, { chatId: 'oc_x', intervalMs: 0, bufferThreshold: 1 })
    // create failed -> degraded; updates/finish must not throw
    await session.update('x')
    const finish = await session.finish('x', 'completed')
    expect(session.cardId).toBe('')
    expect(finish).toMatchObject({ delivered: false, finalTextConfirmed: false })
  })

  it('keeps a preview session alive after a transient content failure and confirms the final suffix', async () => {
    const calls: RecordedCall[] = []
    const connection = fakeConnection(calls)
    let contentAttempts = 0
    connection.rawClient.cardkit.v1.cardElement.content = async (payload: any) => {
      contentAttempts += 1
      calls.push({ kind: 'cardElement.content', data: payload.data, path: payload.path })
      if (contentAttempts === 1) throw new Error('temporary cardkit content failure')
      return { code: 0, data: {} }
    }
    const session = await createLarkStreamingCardSession(connection, {
      chatId: 'oc_x',
      intervalMs: 0,
      bufferThreshold: 1
    })

    await session.update('hi')
    await session.update('hi there')
    const finish = await session.finish('hi there friend', 'completed')

    expect(contentAttempts).toBe(2)
    const patches = calls.filter(c => c.kind === 'cardElement.content')
    expect(patches[0]!.data.content).toBe(' there')
    expect(patches[1]!.data.content).toBe(' there friend')
    expect(finish).toMatchObject({ delivered: true, finalTextConfirmed: true })
  })

  it('replaces the preview element on finalize when the final answer is not a suffix', async () => {
    const calls: RecordedCall[] = []
    const session = await createLarkStreamingCardSession(fakeConnection(calls), {
      chatId: 'oc_x',
      intervalMs: 0,
      bufferThreshold: 1
    })

    await session.update("I'll")
    const finish = await session.finish('Final answer', 'completed')

    const updates = calls.filter(c => c.kind === 'cardElement.update')
    expect(updates).toHaveLength(2)
    expect(JSON.parse(updates[1]!.data.element)).toMatchObject({
      tag: 'markdown',
      element_id: 'content',
      content: 'Final answer'
    })
    expect(finish).toMatchObject({ delivered: true, finalTextConfirmed: true })
  })

  it('returns an unconfirmed final result when the final write fails', async () => {
    const calls: RecordedCall[] = []
    const connection = fakeConnection(calls)
    connection.rawClient.cardkit.v1.cardElement.update = async (payload: any) => {
      calls.push({ kind: 'cardElement.update', data: payload.data, path: payload.path })
      throw new Error('cardkit update down')
    }
    const session = await createLarkStreamingCardSession(connection, {
      chatId: 'oc_x',
      intervalMs: 0,
      bufferThreshold: 1
    })

    const finish = await session.finish('Final answer', 'completed')

    expect(finish).toMatchObject({
      delivered: true,
      finalTextConfirmed: false,
      fallbackReason: 'final_text_unconfirmed'
    })
  })

  it('degrades without sending when CardKit create returns a non-success code', async () => {
    const calls: RecordedCall[] = []
    const connection = fakeConnection(calls)
    connection.rawClient.cardkit.v1.card.create = async (payload: any) => {
      calls.push({ kind: 'card.create', data: payload.data })
      return { code: 999, msg: 'bad card', data: { card_id: 'card-bad' } }
    }

    const session = await createLarkStreamingCardSession(connection, {
      chatId: 'oc_x',
      intervalMs: 0,
      bufferThreshold: 1
    })

    expect(session.cardId).toBe('')
    expect(calls.some(c => c.kind === 'message.create' || c.kind === 'message.reply')).toBe(false)
  })

  it('replies to the root message without creating a Lark topic', async () => {
    const calls: RecordedCall[] = []
    const session = await createLarkStreamingCardSession(fakeConnection(calls), {
      chatId: 'oc_x',
      rootId: 'om_root',
      idempotencyKey: 'uuid-stream',
      intervalMs: 0,
      bufferThreshold: 1
    })

    expect(session.messageId).toBe('msg-2')
    expect(calls.some(c => c.kind === 'message.create')).toBe(false)
    const reply = calls.find(c => c.kind === 'message.reply')
    expect(reply).toMatchObject({
      path: { message_id: 'om_root' },
      data: {
        msg_type: 'interactive',
        reply_in_thread: false,
        uuid: 'uuid-stream'
      }
    })
  })

  it('renders fenced code blocks as visible inline-code lines for CardKit markdown', async () => {
    const calls: RecordedCall[] = []
    const session = await createLarkStreamingCardSession(fakeConnection(calls), {
      chatId: 'oc_x',
      intervalMs: 0,
      bufferThreshold: 1
    })

    await session.update('Rows:\n```csv\nn,square\n1,1\n2,4\n```')

    const replace = calls.find(c => c.kind === 'cardElement.update')
    const element = JSON.parse(replace!.data.element)
    expect(element.content).toBe('Rows:\n`csv`\n`n,square`\n`1,1`\n`2,4`')
    expect(element.content).not.toContain('```')
  })

  it('retries an interactive reply when Feishu has not made the new card_id visible yet', async () => {
    const calls: RecordedCall[] = []
    let replyAttempts = 0
    const connection = fakeConnection(calls)
    const originalReply = connection.rawClient.im.v1.message.reply
    connection.rawClient.im.v1.message.reply = async (payload: any) => {
      replyAttempts += 1
      calls.push({ kind: 'message.reply', data: payload.data, path: payload.path })
      if (replyAttempts === 1) {
        throw {
          response: {
            data: {
              code: 230099,
              msg: 'Failed to create card content, ext=ErrCode: 11310; ErrMsg: cardid is invalid; '
            }
          }
        }
      }
      return originalReply(payload)
    }

    const session = await createLarkStreamingCardSession(connection, {
      chatId: 'oc_x',
      rootId: 'om_root',
      intervalMs: 0,
      bufferThreshold: 1,
      cardIdRetryDelaysMs: [0]
    })

    expect(session.messageId).toBe('msg-2')
    expect(replyAttempts).toBe(2)
  })

  it('keeps retrying invalid card_id with the default visibility wait budget', async () => {
    const calls: RecordedCall[] = []
    let replyAttempts = 0
    const connection = fakeConnection(calls)
    const originalReply = connection.rawClient.im.v1.message.reply
    connection.rawClient.im.v1.message.reply = async (payload: any) => {
      replyAttempts += 1
      calls.push({ kind: 'message.reply', data: payload.data, path: payload.path })
      if (replyAttempts <= 2) {
        throw {
          response: {
            data: {
              code: 230099,
              msg: 'Failed to create card content, ext=ErrCode: 11310; ErrMsg: cardid is invalid; '
            }
          }
        }
      }
      return originalReply(payload)
    }

    const session = await createLarkStreamingCardSession(connection, {
      chatId: 'oc_x',
      rootId: 'om_root',
      intervalMs: 0,
      bufferThreshold: 1
    })

    expect(session.messageId).toBe('msg-2')
    expect(replyAttempts).toBe(3)
  })
})
