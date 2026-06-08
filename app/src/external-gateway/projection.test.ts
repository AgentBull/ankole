import 'reflect-metadata'
import { afterAll, beforeAll, describe, expect, it } from 'bun:test'
import { and, eq, like } from 'drizzle-orm'
import { loadTestEnvFiles } from '@/common/tests/load-test-env'
import type { ExternalGatewayMessageInput, ExternalGatewayReactionEvent, ExternalGatewayRoomInput } from './core/events'

await loadTestEnvFiles()

const { DB } = await import('@/common/database')
const { ExternalRooms, ExternalMessages } = await import('@/common/db-schema')
const { DrizzleExternalGatewayProjectionSink } = await import('./core/projection')

const testPrefix = `__test_external_gateway_projection_${Date.now()}_${Math.random().toString(36).slice(2)}`
const sink = new DrizzleExternalGatewayProjectionSink()

beforeAll(cleanupProjectionRows)
afterAll(cleanupProjectionRows)

describe('DrizzleExternalGatewayProjectionSink', () => {
  it('dedupes rooms and messages by external room id and message id', async () => {
    const roomId = `${testPrefix}:feishu-group`

    await sink.projectMessage({
      room: room({ id: roomId, title: 'Feishu group' }),
      message: message({ id: 'shared-message', threadId: 'factory-a:thread-1', text: 'first observation' })
    })
    await sink.projectMessage({
      room: room({ id: roomId, title: 'Feishu group' }),
      message: message({ id: 'shared-message', threadId: 'factory-b:thread-1', text: 'latest observation' })
    })

    const rooms = await DB.select().from(ExternalRooms).where(eq(ExternalRooms.id, roomId))
    expect(rooms).toHaveLength(1)

    const messages = await DB.select().from(ExternalMessages).where(eq(ExternalMessages.roomId, roomId))
    expect(messages).toHaveLength(1)
    expect(messages[0]!.messageId).toBe('shared-message')
    expect(messages[0]!.text).toBe('latest observation')
  })

  it('keeps different messages under the same external room by message id', async () => {
    const roomId = `${testPrefix}:threaded-room`

    const first = await sink.projectMessage({
      room: room({ id: roomId }),
      message: message({ id: 'thread-a-message', threadId: 'external:room:thread-a', text: 'root' })
    })
    const second = await sink.projectMessage({
      room: room({ id: roomId }),
      message: message({ id: 'thread-b-message', threadId: 'external:room:thread-b', text: 'reply scope' })
    })

    expect(first.roomId).toBe(second.roomId)
    expect(first.messageId).toBe('thread-a-message')
    expect(second.messageId).toBe('thread-b-message')
  })

  it('creates separate room facts for separate external room ids', async () => {
    const first = await sink.projectMessage({
      room: room({ id: `${testPrefix}:room-a` }),
      message: message({ id: 'room-a-message', threadId: 'external:a:thread', text: 'a' })
    })
    const second = await sink.projectMessage({
      room: room({ id: `${testPrefix}:room-b` }),
      message: message({ id: 'room-b-message', threadId: 'external:b:thread', text: 'b' })
    })

    expect(first.roomId).not.toBe(second.roomId)
  })

  it('updates repeated observations in place without creating an edit contract', async () => {
    const roomId = `${testPrefix}:repeat-room`
    const threadId = 'external:repeat:thread'

    const inserted = await sink.projectMessage({
      room: room({ id: roomId }),
      message: message({
        id: 'repeated-message',
        threadId,
        text: 'before',
        sentAt: new Date('2026-06-03T01:00:00.000Z')
      })
    })
    await Bun.sleep(20)
    const updated = await sink.projectMessage({
      room: room({ id: roomId }),
      message: message({
        id: 'repeated-message',
        threadId,
        text: 'after',
        sentAt: new Date('2026-06-03T01:00:00.000Z')
      })
    })

    expect(updated.roomId).toBe(inserted.roomId)
    expect(updated.messageId).toBe(inserted.messageId)
    const rows = await DB.select()
      .from(ExternalMessages)
      .where(and(eq(ExternalMessages.roomId, roomId), eq(ExternalMessages.messageId, 'repeated-message')))
    expect(rows).toHaveLength(1)
    expect(updated.text).toBe('after')
    expect(updated.sentAt?.toISOString()).toBe('2026-06-03T01:00:00.000Z')
    expect(updated.updatedAt.getTime()).toBeGreaterThanOrEqual(inserted.updatedAt.getTime())
  })

  it('preserves empty string text as a visible latest-state value', async () => {
    const threadId = 'external:empty:thread'
    const row = await sink.projectMessage({
      room: room({ id: `${testPrefix}:empty-text-room` }),
      message: message({ id: 'empty-text-message', threadId, text: '' })
    })

    expect(row.text).toBe('')
    expect(row.raw).toEqual({ id: 'empty-text-message', text: '' })
  })

  it('hard-deletes projected messages by external room and message id', async () => {
    const roomId = `${testPrefix}:delete-room`
    await sink.projectMessage({
      room: room({ id: roomId }),
      message: message({ id: 'deleted-message', threadId: 'external:delete:thread', text: 'delete me' })
    })

    expect(
      await sink.projectDelete({
        room: room({ id: roomId }),
        messageId: 'deleted-message'
      })
    ).toBe(true)

    const messages = await DB.select().from(ExternalMessages).where(eq(ExternalMessages.roomId, roomId))
    expect(messages).toEqual([])
  })

  it('updates reactions from normalized provider events only when the message exists', async () => {
    const roomId = `${testPrefix}:reaction-room`
    const threadId = 'external:reaction:thread'

    expect(await sink.projectReaction(reactionEvent({ roomId, threadId, messageId: 'missing-message' }))).toBe(false)

    await sink.projectMessage({
      room: room({ id: roomId }),
      message: message({ id: 'reacted-message', threadId, text: 'react to me' })
    })

    expect(
      await sink.projectReaction(
        reactionEvent({
          roomId,
          threadId,
          messageId: 'reacted-message',
          rawEmoji: '+1',
          userId: 'user-1'
        })
      )
    ).toBe(true)

    const [reacted] = await DB.select()
      .from(ExternalMessages)
      .where(and(eq(ExternalMessages.roomId, roomId), eq(ExternalMessages.messageId, 'reacted-message')))
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
      room: room({ id: roomId }),
      message: message({
        id: 'reacted-message',
        threadId,
        text: 'later observation but still reacted'
      })
    })
    const [updatedWithReaction] = await DB.select()
      .from(ExternalMessages)
      .where(and(eq(ExternalMessages.roomId, roomId), eq(ExternalMessages.messageId, 'reacted-message')))
    expect(updatedWithReaction!.text).toBe('later observation but still reacted')
    expect(updatedWithReaction!.reactions).toEqual(reacted!.reactions)

    expect(
      await sink.projectReaction(
        reactionEvent({
          added: false,
          roomId,
          threadId,
          messageId: 'reacted-message',
          rawEmoji: '+1',
          userId: 'user-1'
        })
      )
    ).toBe(true)

    const [withoutReaction] = await DB.select()
      .from(ExternalMessages)
      .where(and(eq(ExternalMessages.roomId, roomId), eq(ExternalMessages.messageId, 'reacted-message')))
    expect(withoutReaction!.reactions).toEqual({})
  })

  it('persists serializable normalized message facts for files, links, formatting, and raw payloads', async () => {
    const threadId = 'external:json:thread'
    const row = await sink.projectMessage({
      room: room({ id: `${testPrefix}:json-room` }),
      message: message({
        id: 'json-message',
        threadId,
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
    expect(row.mentions.length > 0).toBe(false)
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

function room(input: {
  id: string
  isDM?: boolean
  title?: string | null
}): Required<Pick<ExternalGatewayRoomInput, 'id'>> & ExternalGatewayRoomInput {
  return {
    id: input.id,
    isDM: input.isDM ?? false,
    metadata: { provider: 'test' },
    name: input.title ?? null,
    raw: {
      id: input.id,
      isDM: input.isDM ?? false
    },
    roomVisibility: 'unknown'
  }
}

function reactionEvent(input: {
  added?: boolean
  message?: ExternalGatewayMessageInput
  messageId: string
  rawEmoji?: string
  roomId: string
  threadId: string
  userId?: string
}): ExternalGatewayReactionEvent {
  const userId = input.userId ?? 'user-1'

  return {
    added: input.added ?? true,
    emoji: 'thumbs_up',
    message: input.message,
    messageId: input.messageId,
    raw: { messageId: input.messageId },
    rawEmoji: input.rawEmoji ?? 'thumbs_up',
    room: room({ id: input.roomId }),
    threadId: input.threadId,
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
  id: string
  links?: Array<{ title?: string; url: string }>
  raw?: unknown
  sentAt?: Date
  text: string
  threadId: string
}): ExternalGatewayMessageInput {
  return {
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
      edited: false
    },
    attachments: input.attachments ?? [],
    links: input.links ?? []
  }
}

async function cleanupProjectionRows() {
  await DB.delete(ExternalRooms).where(like(ExternalRooms.id, `${testPrefix}%`))
}
