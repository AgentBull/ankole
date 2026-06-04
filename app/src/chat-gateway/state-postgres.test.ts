import 'reflect-metadata'
import { afterAll, beforeAll, describe, expect, it } from 'bun:test'
import { Message } from './core/message'
import type { QueueEntry } from './core/types'
import { and, eq } from 'drizzle-orm'
import { loadTestEnvFiles } from '@/common/tests/load-test-env'

await loadTestEnvFiles()

const { DB } = await import('@/common/database')
const { ChatStateCache, ChatStateLists, ChatStateLocks, ChatStateQueues, ChatStateSubscriptions } =
  await import('@/common/db-schema')
const { createBullXChatStateStore } = await import('./core/state-postgres')

const keyPrefix = `__test.chat_gateway.state.${Date.now()}.${Math.random().toString(36).slice(2)}`

async function cleanupStateRows() {
  await DB.delete(ChatStateSubscriptions).where(eq(ChatStateSubscriptions.keyPrefix, keyPrefix))
  await DB.delete(ChatStateLocks).where(eq(ChatStateLocks.keyPrefix, keyPrefix))
  await DB.delete(ChatStateCache).where(eq(ChatStateCache.keyPrefix, keyPrefix))
  await DB.delete(ChatStateLists).where(eq(ChatStateLists.keyPrefix, keyPrefix))
  await DB.delete(ChatStateQueues).where(eq(ChatStateQueues.keyPrefix, keyPrefix))
}

beforeAll(cleanupStateRows)
afterAll(cleanupStateRows)

describe('BullXPostgresChatStateStore', () => {
  it('supports subscriptions, locks, cache TTLs, lists, and queues', async () => {
    const state = createBullXChatStateStore({ keyPrefix })
    await state.connect()

    await state.subscribe('thread-subscription')
    expect(await state.isSubscribed('thread-subscription')).toBe(true)
    await state.unsubscribe('thread-subscription')
    expect(await state.isSubscribed('thread-subscription')).toBe(false)

    const lock = await state.acquireLock('thread-lock', 1_000)
    expect(lock).not.toBeNull()
    expect(await state.acquireLock('thread-lock', 1_000)).toBeNull()
    expect(await state.extendLock(lock!, 1_000)).toBe(true)
    await state.releaseLock(lock!)
    const reacquired = await state.acquireLock('thread-lock', 1_000)
    expect(reacquired).not.toBeNull()
    await state.forceReleaseLock('thread-lock')
    expect(await state.acquireLock('thread-lock', 1_000)).not.toBeNull()

    await state.set('cache-key', { value: 1 }, 50)
    expect(await state.get<{ value: number }>('cache-key')).toEqual({ value: 1 })
    expect(await state.setIfNotExists('cache-key', { value: 2 })).toBe(false)
    await Bun.sleep(80)
    expect(await state.get('cache-key')).toBeNull()
    expect(await state.setIfNotExists('cache-key', { value: 3 })).toBe(true)
    expect(await state.get<{ value: number }>('cache-key')).toEqual({ value: 3 })
    await state.delete('cache-key')
    expect(await state.get('cache-key')).toBeNull()

    await state.appendToList('list-key', 1, { maxLength: 2 })
    await state.appendToList('list-key', 2, { maxLength: 2 })
    await state.appendToList('list-key', 3, { maxLength: 2 })
    expect(await state.getList('list-key')).toEqual([2, 3])

    const firstDepth = await state.enqueue('thread-queue', queueEntry('message-1'), 2)
    const secondDepth = await state.enqueue('thread-queue', queueEntry('message-2'), 2)
    const thirdDepth = await state.enqueue('thread-queue', queueEntry('message-3'), 2)
    expect([firstDepth, secondDepth, thirdDepth]).toEqual([1, 2, 2])
    expect(await state.queueDepth('thread-queue')).toBe(2)
    expect((await state.dequeue('thread-queue'))?.message.id).toBe('message-2')
    expect((await state.dequeue('thread-queue'))?.message.id).toBe('message-3')
    expect(await state.dequeue('thread-queue')).toBeNull()
    expect(await state.queueDepth('thread-queue')).toBe(0)

    await state.disconnect()

    const residualQueueRows = await DB.select()
      .from(ChatStateQueues)
      .where(and(eq(ChatStateQueues.keyPrefix, keyPrefix), eq(ChatStateQueues.threadId, 'thread-queue')))
    expect(residualQueueRows).toEqual([])
  })
})

function queueEntry(id: string): QueueEntry {
  return {
    enqueuedAt: Date.now(),
    expiresAt: Date.now() + 60_000,
    message: message(id)
  }
}

function message(id: string): Message {
  return new Message({
    id,
    threadId: 'thread-queue',
    text: id,
    formatted: {
      type: 'root',
      children: [
        {
          type: 'paragraph',
          children: [{ type: 'text', value: id }]
        }
      ]
    } as never,
    raw: { id },
    author: {
      userId: 'user-1',
      userName: 'user',
      fullName: 'User',
      isBot: false,
      isMe: false
    },
    metadata: {
      dateSent: new Date(),
      edited: false
    },
    attachments: []
  })
}
