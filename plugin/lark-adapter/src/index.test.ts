import { describe, expect, it } from 'bun:test'
import { decodeThreadId } from '@larksuite/vercel-chat-adapter'
import { createBullXLarkAdapter, LarkAdapterConfigError } from './index'

describe('BullX Lark chat adapter', () => {
  it('uses Lark user_id for inbound message authors and DM placeholders', async () => {
    const subjects: any[] = []
    const adapter = createAdapter(subjects)
    const message = await adapter.parseMessage(
      normalizedMessage({
        raw: {
          sender: {
            sender_id: {
              open_id: 'ou_open_id',
              user_id: 'user_123'
            }
          }
        }
      }) as never
    )

    expect(message.author.userId).toBe('user_123')
    expect(message.author.userName).toBe('Alice')
    await Bun.sleep(0)
    expect(subjects[0]).toMatchObject({
      provider: 'lark-main',
      externalId: 'user_123',
      displayName: 'Alice',
      metadata: {
        app_id: 'cli_test',
        open_id: 'ou_open_id',
        source: 'message'
      }
    })

    const dmThreadId = await adapter.openDM('user_123')
    expect(decodeThreadId(dmThreadId)).toEqual({ chatId: 'user_123', rootId: '' })
    expect(adapter.isDM(dmThreadId)).toBe(true)
  })

  it('fails closed instead of falling back to open_id when a message lacks user_id', async () => {
    const adapter = createAdapter()

    await expect(
      adapter.parseMessage(
        normalizedMessage({
          raw: {
            sender: {
              sender_id: {
                open_id: 'ou_open_id'
              }
            }
          }
        }) as never
      )
    ).rejects.toThrow(LarkAdapterConfigError)
  })

  it('waits for platform subject persistence before accepting inbound messages', async () => {
    const adapter = createAdapter(undefined, async () => {
      throw new Error('principal store unavailable')
    })

    await expect(
      adapter.parseMessage(
        normalizedMessage({
          raw: {
            sender: {
              sender_id: {
                user_id: 'user_123'
              }
            }
          }
        }) as never
      )
    ).rejects.toThrow('principal store unavailable')
  })

  it('emits card actions and reactions with operator user_id only', async () => {
    const subjects: any[] = []
    const adapter = createAdapter(subjects) as any
    const actions: any[] = []
    const reactions: any[] = []
    adapter.chat = {
      processAction: (action: unknown) => actions.push(action),
      processReaction: (reaction: unknown) => reactions.push(reaction)
    }
    adapter.fetchRootIdFor = async () => 'om_root'
    adapter.fetchChatAndRootFor = async () => ({ chatId: 'oc_chat', rootId: 'om_root' })

    await adapter.handleCardAction({
      messageId: 'om_message',
      chatId: 'oc_chat',
      action: { name: 'approve', value: { approved: true } },
      operator: { userId: 'user_123', openId: 'ou_open_id', name: 'Alice' }
    })
    await adapter.handleReaction({
      action: 'added',
      emojiType: 'THUMBSUP',
      messageId: 'om_message',
      operator: { userId: 'user_123', openId: 'ou_open_id' }
    })

    expect(actions[0].user.userId).toBe('user_123')
    expect(reactions[0].user.userId).toBe('user_123')
    expect(subjects.map(subject => [subject.provider, subject.externalId])).toEqual([
      ['lark-main', 'user_123'],
      ['lark-main', 'user_123']
    ])

    await adapter.handleCardAction({
      messageId: 'om_message',
      chatId: 'oc_chat',
      action: { name: 'approve', value: {} },
      operator: { openId: 'ou_open_id' }
    })
    await adapter.handleReaction({
      action: 'added',
      emojiType: 'THUMBSUP',
      messageId: 'om_message',
      operator: { openId: 'ou_open_id' }
    })

    expect(actions).toHaveLength(1)
    expect(reactions).toHaveLength(1)
  })
})

function createAdapter(
  subjects: any[] = [],
  upsertPlatformSubject: (
    input: any
  ) => Promise<{ externalIdentityId: string; principalUid: string }> = async input => {
    subjects.push(input)
    return { principalUid: input.externalId, externalIdentityId: `${input.provider}:${input.externalId}` }
  }
) {
  return createBullXLarkAdapter({
    agent: {},
    channel: {
      adapter: 'lark',
      enabled: true,
      name: 'lark'
    },
    config: {
      appId: 'cli_test',
      appSecret: 'secret',
      platformProviderId: 'lark-main',
      userName: 'BullX'
    },
    projection: {},
    externalIdentities: {
      upsertPlatformSubject
    }
  })
}

function normalizedMessage(overrides: Record<string, unknown> = {}) {
  return {
    messageId: 'om_message',
    chatId: 'oc_chat',
    rootId: '',
    threadId: undefined,
    content: 'hello',
    senderId: 'ou_open_id',
    senderName: 'Alice',
    createTime: `${Date.now()}`,
    mentionedBot: false,
    ...overrides
  }
}
