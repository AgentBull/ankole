import { describe, expect, it } from 'bun:test'
import type { SharedLarkConnection } from './connection'
import { createLarkStreamingCardSession } from './streaming-card'

interface RecordedCall {
  kind: 'card.create' | 'card.settings' | 'cardElement.update' | 'cardElement.content' | 'message.create' | 'message.reply'
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
            calls.push({ kind: 'message.reply', data: payload.data })
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
    await session.finish('hi there', 'completed')

    // first content write replaces the placeholder element with a full markdown element
    const replace = calls.find(c => c.kind === 'cardElement.update')
    expect(replace?.path).toEqual({ card_id: 'card-1', element_id: 'content' })
    expect(JSON.parse(replace!.data.element)).toMatchObject({ tag: 'markdown', element_id: 'content', content: 'hi' })

    // subsequent writes patch element content only
    const patch = calls.find(c => c.kind === 'cardElement.content')
    expect(patch?.path).toEqual({ card_id: 'card-1', element_id: 'content' })
    expect(patch!.data.content).toBe('hi there')

    // finish closes streaming mode
    const settings = calls.find(c => c.kind === 'card.settings')
    expect(settings?.path).toEqual({ card_id: 'card-1' })
    expect(JSON.parse(settings!.data.settings).config.streaming_mode).toBe(false)

    // sequences strictly increase across element/settings writes
    const seqs = calls.filter(c => typeof c.data?.sequence === 'number').map(c => c.data.sequence as number)
    expect(seqs.length).toBeGreaterThanOrEqual(3)
    for (let i = 1; i < seqs.length; i++) expect(seqs[i]!).toBeGreaterThan(seqs[i - 1]!)
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
    await session.finish('x', 'completed')
    expect(session.cardId).toBe('')
  })
})
