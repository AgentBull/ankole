import 'reflect-metadata'
import { afterAll, beforeAll, describe, expect, it } from 'bun:test'
import { emoji as coreEmoji } from './core/emoji'
import { Message } from './core/message'
import type { Channel, ReactionEvent, Thread } from './core/types'
import { eq, like } from 'drizzle-orm'
import { loadTestEnvFiles } from '@/common/tests/load-test-env'

await loadTestEnvFiles()

const { DB } = await import('@/common/database')
const { ChatChannels, ChatMessages } = await import('@/common/db-schema')
const { DrizzleChatGatewayProjectionSink } = await import('./core/projection')

const testPrefix = `__test_chat_gateway_projection_${Date.now()}_${Math.random().toString(36).slice(2)}`
const sink = new DrizzleChatGatewayProjectionSink()

beforeAll(cleanupProjectionRows)
afterAll(cleanupProjectionRows)

describe('DrizzleChatGatewayProjectionSink', () => {
  it('dedupes channels and messages by Chat SDK channel id and message id', async () => {
    const channelId = `${testPrefix}:feishu-group`

    await sink.projectMessage({
      thread: chatThread({ channelId, threadId: 'factory-a:thread-1', title: 'Feishu group' }),
      message: message({ id: 'shared-message', threadId: 'factory-a:thread-1', text: 'first observation' })
    })
    await sink.projectMessage({
      thread: chatThread({ channelId, threadId: 'factory-b:thread-1', title: 'Feishu group' }),
      message: message({ id: 'shared-message', threadId: 'factory-b:thread-1', text: 'latest observation' })
    })

    const channels = await DB.select().from(ChatChannels).where(eq(ChatChannels.id, channelId))
    expect(channels).toHaveLength(1)

    const messages = await DB.select().from(ChatMessages).where(eq(ChatMessages.channelId, channelId))
    expect(messages).toHaveLength(1)
    expect(messages[0]!.messageId).toBe('shared-message')
    expect(messages[0]!.text).toBe('latest observation')
  })

  it('keeps different thread ids under the same Chat SDK channel', async () => {
    const channelId = `${testPrefix}:threaded-channel`

    const first = await sink.projectMessage({
      thread: chatThread({ channelId, threadId: 'chat:channel:thread-a' }),
      message: message({ id: 'thread-a-message', threadId: 'chat:channel:thread-a', text: 'root' })
    })
    const second = await sink.projectMessage({
      thread: chatThread({ channelId, threadId: 'chat:channel:thread-b' }),
      message: message({ id: 'thread-b-message', threadId: 'chat:channel:thread-b', text: 'reply scope' })
    })

    expect(first.channelId).toBe(second.channelId)
    expect(first.threadId).toBe('chat:channel:thread-a')
    expect(second.threadId).toBe('chat:channel:thread-b')
  })

  it('creates separate channel facts for separate Chat SDK channel ids', async () => {
    const first = await sink.projectMessage({
      thread: chatThread({ channelId: `${testPrefix}:channel-a`, threadId: 'chat:a:thread' }),
      message: message({ id: 'channel-a-message', threadId: 'chat:a:thread', text: 'a' })
    })
    const second = await sink.projectMessage({
      thread: chatThread({ channelId: `${testPrefix}:channel-b`, threadId: 'chat:b:thread' }),
      message: message({ id: 'channel-b-message', threadId: 'chat:b:thread', text: 'b' })
    })

    expect(first.channelId).not.toBe(second.channelId)
  })

  it('updates edited Chat SDK messages in place and sets edited_at', async () => {
    const channelId = `${testPrefix}:edit-channel`
    const thread = chatThread({ channelId, threadId: 'chat:edit:thread' })
    const editAt = new Date('2026-06-03T02:00:00.000Z')

    const inserted = await sink.projectMessage({
      thread,
      message: message({
        id: 'editable-message',
        threadId: 'chat:edit:thread',
        text: 'before',
        sentAt: new Date('2026-06-03T01:00:00.000Z')
      })
    })
    await Bun.sleep(20)
    const edited = await sink.projectMessage({
      thread,
      message: message({
        id: 'editable-message',
        threadId: 'chat:edit:thread',
        text: 'after',
        sentAt: new Date('2026-06-03T01:00:00.000Z'),
        editedAt: editAt
      })
    })

    expect(edited.id).toBe(inserted.id)
    expect(edited.text).toBe('after')
    expect(edited.sentAt?.toISOString()).toBe('2026-06-03T01:00:00.000Z')
    expect(edited.editedAt?.toISOString()).toBe(editAt.toISOString())
    expect(edited.updatedAt.getTime()).toBeGreaterThanOrEqual(inserted.updatedAt.getTime())
  })

  it('preserves empty string text as a visible latest-state value', async () => {
    const row = await sink.projectMessage({
      thread: chatThread({ channelId: `${testPrefix}:empty-text-channel`, threadId: 'chat:empty:thread' }),
      message: message({ id: 'empty-text-message', threadId: 'chat:empty:thread', text: '' })
    })

    expect(row.text).toBe('')
    expect(row.raw).toEqual({ id: 'empty-text-message', text: '' })
  })

  it('hard-deletes projected messages by Chat SDK thread channel and message id', async () => {
    const channelId = `${testPrefix}:delete-channel`
    await sink.projectMessage({
      thread: chatThread({ channelId, threadId: 'chat:delete:thread' }),
      message: message({ id: 'deleted-message', threadId: 'chat:delete:thread', text: 'delete me' })
    })

    expect(
      await sink.projectDelete({
        thread: chatThread({ channelId, threadId: 'chat:delete:different-thread' }),
        messageId: 'deleted-message'
      })
    ).toBe(true)

    const messages = await DB.select().from(ChatMessages).where(eq(ChatMessages.channelId, channelId))
    expect(messages).toEqual([])
  })

  it('updates reactions from Chat SDK ReactionEvent only when the message exists', async () => {
    const channelId = `${testPrefix}:reaction-channel`
    const thread = chatThread({ channelId, threadId: 'chat:reaction:thread' })

    expect(await sink.projectReaction(reactionEvent({ thread, messageId: 'missing-message' }))).toBe(false)

    const messageRow = await sink.projectMessage({
      thread,
      message: message({ id: 'reacted-message', threadId: 'chat:reaction:thread', text: 'react to me' })
    })

    expect(
      await sink.projectReaction(
        reactionEvent({
          thread,
          messageId: 'reacted-message',
          rawEmoji: '+1',
          userId: 'user-1'
        })
      )
    ).toBe(true)

    const [reacted] = await DB.select().from(ChatMessages).where(eq(ChatMessages.id, messageRow.id))
    expect(reacted!.reactions).toEqual({
      '+1': {
        emoji: 'thumbs_up',
        rawEmoji: '+1',
        count: 1,
        actors: {
          'user-1': {
            userId: 'user-1',
            userName: 'user',
            fullName: 'User',
            isBot: false,
            isMe: false
          }
        },
        raw: { messageId: 'reacted-message' }
      }
    })

    await sink.projectMessage({
      thread,
      message: message({
        id: 'reacted-message',
        threadId: 'chat:reaction:thread',
        text: 'edited but still reacted',
        editedAt: new Date('2026-06-03T03:00:00.000Z')
      })
    })
    const [editedWithReaction] = await DB.select().from(ChatMessages).where(eq(ChatMessages.id, messageRow.id))
    expect(editedWithReaction!.text).toBe('edited but still reacted')
    expect(editedWithReaction!.reactions).toEqual(reacted!.reactions)

    expect(
      await sink.projectReaction(
        reactionEvent({
          added: false,
          thread,
          messageId: 'reacted-message',
          rawEmoji: '+1',
          userId: 'user-1'
        })
      )
    ).toBe(true)

    const [withoutReaction] = await DB.select().from(ChatMessages).where(eq(ChatMessages.id, messageRow.id))
    expect(withoutReaction!.reactions).toEqual({})
  })

  it('persists serializable Chat SDK message facts for files, links, formatting, and raw payloads', async () => {
    const row = await sink.projectMessage({
      thread: chatThread({ channelId: `${testPrefix}:json-channel`, threadId: 'chat:json:thread' }),
      message: message({
        id: 'json-message',
        threadId: 'chat:json:thread',
        text: 'card text',
        attachments: [{ type: 'file', name: 'report.pdf', mimeType: 'application/pdf', size: 42 }],
        links: [{ url: 'https://example.com', title: 'Example' }],
        raw: { platformPayload: { id: 'raw-1' }, card: { title: 'Status' } }
      })
    })

    expect(row.author).toEqual({
      userId: 'user-1',
      userName: 'user',
      fullName: 'User',
      isBot: false,
      isMe: false
    })
    expect(row.authorId).toBe('user-1')
    expect(row.userKey).toBeNull()
    expect(row.isMention).toBe(false)
    expect(row.formatted).toEqual({
      type: 'root',
      children: [
        {
          type: 'paragraph',
          children: [{ type: 'text', value: 'card text' }]
        }
      ]
    })
    expect(row.attachments).toEqual([{ type: 'file', name: 'report.pdf', mimeType: 'application/pdf', size: 42 }])
    expect(row.links).toEqual([{ url: 'https://example.com', title: 'Example' }])
    expect(row.metadata).toEqual({
      dateSent: '2026-06-03T01:00:00.000Z',
      edited: false
    })
    expect(row.raw).toEqual({ platformPayload: { id: 'raw-1' }, card: { title: 'Status' } })
  })
})

function chatThread(input: {
  channelId: string
  isDM?: boolean
  threadId: string
  title?: string | null
}): Thread<Record<string, unknown>> {
  const channel = chatChannel(input)

  return {
    id: input.threadId,
    channel,
    channelId: input.channelId,
    channelVisibility: 'unknown',
    isDM: input.isDM ?? false,
    toJSON() {
      return {
        _type: 'chat:Thread',
        adapterName: 'test',
        channelId: input.channelId,
        channelVisibility: 'unknown',
        id: input.threadId,
        isDM: input.isDM ?? false
      }
    }
  } as unknown as Thread<Record<string, unknown>>
}

function chatChannel(input: {
  channelId: string
  isDM?: boolean
  title?: string | null
}): Channel<Record<string, unknown>> {
  return {
    id: input.channelId,
    channelVisibility: 'unknown',
    isDM: input.isDM ?? false,
    name: input.title ?? null,
    toJSON() {
      return {
        _type: 'chat:Channel',
        adapterName: 'test',
        channelVisibility: 'unknown',
        id: input.channelId,
        isDM: input.isDM ?? false
      }
    }
  } as unknown as Channel<Record<string, unknown>>
}

function reactionEvent(input: {
  added?: boolean
  message?: Message
  messageId: string
  rawEmoji?: string
  thread: Thread<Record<string, unknown>>
  userId?: string
}): ReactionEvent {
  const userId = input.userId ?? 'user-1'

  return {
    adapter: {} as never,
    added: input.added ?? true,
    emoji: coreEmoji.thumbs_up,
    message: input.message,
    messageId: input.messageId,
    raw: { messageId: input.messageId },
    rawEmoji: input.rawEmoji ?? 'thumbs_up',
    thread: input.thread,
    threadId: input.thread.id,
    user: {
      userId,
      userName: 'user',
      fullName: 'User',
      isBot: false,
      isMe: false
    }
  }
}

function message(input: {
  attachments?: Array<{ mimeType?: string; name?: string; size?: number; type: 'audio' | 'file' | 'image' | 'video' }>
  editedAt?: Date
  id: string
  links?: Array<{ title?: string; url: string }>
  raw?: unknown
  sentAt?: Date
  text: string
  threadId: string
}): Message {
  return new Message({
    id: input.id,
    threadId: input.threadId,
    text: input.text,
    formatted: {
      type: 'root',
      children: [
        {
          type: 'paragraph',
          children: [{ type: 'text', value: input.text }]
        }
      ]
    } as never,
    raw: input.raw ?? {
      id: input.id,
      text: input.text
    },
    author: {
      userId: 'user-1',
      userName: 'user',
      fullName: 'User',
      isBot: false,
      isMe: false
    },
    metadata: {
      dateSent: input.sentAt ?? new Date('2026-06-03T01:00:00.000Z'),
      edited: input.editedAt !== undefined,
      editedAt: input.editedAt
    },
    attachments: input.attachments ?? [],
    links: input.links ?? []
  })
}

async function cleanupProjectionRows() {
  await DB.delete(ChatChannels).where(like(ChatChannels.id, `${testPrefix}%`))
}
