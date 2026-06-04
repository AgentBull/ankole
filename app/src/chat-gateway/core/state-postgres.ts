import { ConsoleLogger, type Logger } from './logger'
import type { Lock, QueueEntry, StateAdapter } from './types'
import { and, asc, eq, sql } from 'drizzle-orm'
import { DB } from '@/common/database'
import {
  ChatStateCache,
  ChatStateLists,
  ChatStateLocks,
  ChatStateQueues,
  ChatStateSubscriptions
} from '@/common/db-schema'

/**
 * Options for BullX Chat Gateway's PostgreSQL runtime state store.
 */
export interface BullXChatStateStoreOptions {
  /**
   * Namespace applied to every state table row. Chat Gateway uses
   * `bullx-agent:<agent_uid>` so subscriptions, locks, queues, and caches do
   * not leak between agents.
   */
  keyPrefix?: string
  logger?: Logger
}

/**
 * Drizzle/Bun SQL implementation of BullX Chat Gateway runtime state.
 *
 * This is no longer a pluggable SDK backend. BullX Agent runs on Bun and owns
 * one PostgreSQL database boundary, so locks, queues, subscriptions, caches,
 * reply links, and modal context all share the same `chat_state_*` tables.
 */
export class BullXPostgresChatStateStore implements StateAdapter {
  private readonly keyPrefix: string
  private readonly logger: Logger
  private connected = false
  private connectPromise: Promise<void> | null = null

  constructor(options: BullXChatStateStoreOptions = {}) {
    this.keyPrefix = options.keyPrefix ?? 'bullx-agent'
    this.logger = options.logger ?? new ConsoleLogger('info').child('postgres')
  }

  /**
   * Verifies database reachability.
   *
   * This never creates tables. Missing tables are deployment/migration failures
   * and should be visible during startup.
   */
  async connect(): Promise<void> {
    if (this.connected) return

    if (!this.connectPromise) {
      this.connectPromise = (async () => {
        try {
          await DB.execute(sql`SELECT 1`)
          this.connected = true
        } catch (error) {
          this.connectPromise = null
          this.logger.error('Postgres state connect failed', { error })
          throw error
        }
      })()
    }

    await this.connectPromise
  }

  async disconnect(): Promise<void> {
    this.connected = false
    this.connectPromise = null
  }

  async subscribe(threadId: string): Promise<void> {
    this.ensureConnected()
    await DB.insert(ChatStateSubscriptions)
      .values({
        keyPrefix: this.keyPrefix,
        threadId
      })
      .onConflictDoNothing()
  }

  async unsubscribe(threadId: string): Promise<void> {
    this.ensureConnected()
    await DB.delete(ChatStateSubscriptions).where(
      and(eq(ChatStateSubscriptions.keyPrefix, this.keyPrefix), eq(ChatStateSubscriptions.threadId, threadId))
    )
  }

  async isSubscribed(threadId: string): Promise<boolean> {
    this.ensureConnected()
    const rows = await DB.select({ threadId: ChatStateSubscriptions.threadId })
      .from(ChatStateSubscriptions)
      .where(and(eq(ChatStateSubscriptions.keyPrefix, this.keyPrefix), eq(ChatStateSubscriptions.threadId, threadId)))
      .limit(1)

    return rows.length > 0
  }

  async acquireLock(threadId: string, ttlMs: number): Promise<Lock | null> {
    this.ensureConnected()

    const token = generateToken()
    const expiresAt = new Date(Date.now() + ttlMs)
    // Postgres serializes the conflicting row update. The WHERE clause lets an
    // expired lock be replaced atomically while a live lock returns no row.
    const rows = await executeRows<{ thread_id: string; token: string; expires_at: Date }>(sql`
      INSERT INTO ${ChatStateLocks} (key_prefix, thread_id, token, expires_at)
      VALUES (${this.keyPrefix}, ${threadId}, ${token}, ${expiresAt})
      ON CONFLICT (key_prefix, thread_id) DO UPDATE
        SET token = EXCLUDED.token,
            expires_at = EXCLUDED.expires_at,
            updated_at = now()
        WHERE ${ChatStateLocks.expiresAt} <= now()
      RETURNING thread_id, token, expires_at
    `)

    const row = rows[0]
    if (!row) return null

    return {
      threadId: row.thread_id,
      token: row.token,
      expiresAt: row.expires_at.getTime()
    }
  }

  async forceReleaseLock(threadId: string): Promise<void> {
    this.ensureConnected()
    await DB.delete(ChatStateLocks).where(
      and(eq(ChatStateLocks.keyPrefix, this.keyPrefix), eq(ChatStateLocks.threadId, threadId))
    )
  }

  async releaseLock(lock: Lock): Promise<void> {
    this.ensureConnected()
    await DB.delete(ChatStateLocks).where(
      and(
        eq(ChatStateLocks.keyPrefix, this.keyPrefix),
        eq(ChatStateLocks.threadId, lock.threadId),
        eq(ChatStateLocks.token, lock.token)
      )
    )
  }

  async extendLock(lock: Lock, ttlMs: number): Promise<boolean> {
    this.ensureConnected()

    const rows = await executeRows<{ thread_id: string }>(sql`
      UPDATE ${ChatStateLocks}
      SET expires_at = now() + ${ttlMs} * interval '1 millisecond',
          updated_at = now()
      WHERE ${ChatStateLocks.keyPrefix} = ${this.keyPrefix}
        AND ${ChatStateLocks.threadId} = ${lock.threadId}
        AND ${ChatStateLocks.token} = ${lock.token}
        AND ${ChatStateLocks.expiresAt} > now()
      RETURNING thread_id
    `)

    return rows.length > 0
  }

  async get<T = unknown>(key: string): Promise<T | null> {
    this.ensureConnected()

    const rows = await DB.select({ value: ChatStateCache.value })
      .from(ChatStateCache)
      .where(
        and(
          eq(ChatStateCache.keyPrefix, this.keyPrefix),
          eq(ChatStateCache.cacheKey, key),
          sql`(${ChatStateCache.expiresAt} IS NULL OR ${ChatStateCache.expiresAt} > now())`
        )
      )
      .limit(1)

    const row = rows[0]
    if (!row) {
      // PostgreSQL has no native TTL expiry. The state adapter follows the
      // official state-pg behavior and cleans expired rows opportunistically
      // when the owning key is read.
      await DB.delete(ChatStateCache).where(
        and(
          eq(ChatStateCache.keyPrefix, this.keyPrefix),
          eq(ChatStateCache.cacheKey, key),
          sql`${ChatStateCache.expiresAt} <= now()`
        )
      )
      return null
    }

    try {
      return JSON.parse(row.value) as T
    } catch {
      return row.value as T
    }
  }

  async set<T = unknown>(key: string, value: T, ttlMs?: number): Promise<void> {
    this.ensureConnected()

    await DB.insert(ChatStateCache)
      .values({
        keyPrefix: this.keyPrefix,
        cacheKey: key,
        value: JSON.stringify(value),
        expiresAt: ttlMs ? new Date(Date.now() + ttlMs) : null
      })
      .onConflictDoUpdate({
        target: [ChatStateCache.keyPrefix, ChatStateCache.cacheKey],
        set: {
          value: sql`EXCLUDED.value`,
          expiresAt: sql`EXCLUDED.expires_at`,
          updatedAt: sql`now()`
        }
      })
  }

  async setIfNotExists(key: string, value: unknown, ttlMs?: number): Promise<boolean> {
    this.ensureConnected()

    const rows = await DB.insert(ChatStateCache)
      .values({
        keyPrefix: this.keyPrefix,
        cacheKey: key,
        value: JSON.stringify(value),
        expiresAt: ttlMs ? new Date(Date.now() + ttlMs) : null
      })
      .onConflictDoNothing()
      .returning({ cacheKey: ChatStateCache.cacheKey })

    return rows.length > 0
  }

  async delete(key: string): Promise<void> {
    this.ensureConnected()
    await DB.delete(ChatStateCache).where(
      and(eq(ChatStateCache.keyPrefix, this.keyPrefix), eq(ChatStateCache.cacheKey, key))
    )
  }

  async appendToList(key: string, value: unknown, options?: { maxLength?: number; ttlMs?: number }): Promise<void> {
    this.ensureConnected()

    const expiresAt = options?.ttlMs ? new Date(Date.now() + options.ttlMs) : null
    await DB.insert(ChatStateLists).values({
      keyPrefix: this.keyPrefix,
      listKey: key,
      value: JSON.stringify(value),
      expiresAt
    })

    if (options?.maxLength) {
      // Keep the newest maxLength list entries. This intentionally uses SQL
      // because trimming must be based on the current database ordering, not on
      // a stale list read in application memory.
      await DB.execute(sql`
        DELETE FROM ${ChatStateLists}
        WHERE ${ChatStateLists.keyPrefix} = ${this.keyPrefix}
          AND ${ChatStateLists.listKey} = ${key}
          AND ${ChatStateLists.seq} IN (
            SELECT seq FROM ${ChatStateLists}
            WHERE ${ChatStateLists.keyPrefix} = ${this.keyPrefix}
              AND ${ChatStateLists.listKey} = ${key}
            ORDER BY seq ASC
            OFFSET 0
            LIMIT GREATEST(
              (SELECT count(*) FROM ${ChatStateLists}
               WHERE ${ChatStateLists.keyPrefix} = ${this.keyPrefix}
                 AND ${ChatStateLists.listKey} = ${key}) - ${options.maxLength},
              0
            )
          )
      `)
    }

    if (expiresAt) {
      await DB.update(ChatStateLists)
        .set({ expiresAt })
        .where(and(eq(ChatStateLists.keyPrefix, this.keyPrefix), eq(ChatStateLists.listKey, key)))
    }
  }

  async getList<T = unknown>(key: string): Promise<T[]> {
    this.ensureConnected()

    const rows = await DB.select({ value: ChatStateLists.value })
      .from(ChatStateLists)
      .where(
        and(
          eq(ChatStateLists.keyPrefix, this.keyPrefix),
          eq(ChatStateLists.listKey, key),
          sql`(${ChatStateLists.expiresAt} IS NULL OR ${ChatStateLists.expiresAt} > now())`
        )
      )
      .orderBy(asc(ChatStateLists.seq))

    return rows.map(row => JSON.parse(row.value) as T)
  }

  async enqueue(threadId: string, entry: QueueEntry, maxSize: number): Promise<number> {
    this.ensureConnected()

    // Remove expired entries before measuring pressure so stale queued work
    // does not make a healthy queue look full.
    await DB.delete(ChatStateQueues).where(
      and(
        eq(ChatStateQueues.keyPrefix, this.keyPrefix),
        eq(ChatStateQueues.threadId, threadId),
        sql`${ChatStateQueues.expiresAt} <= now()`
      )
    )

    await DB.insert(ChatStateQueues).values({
      keyPrefix: this.keyPrefix,
      threadId,
      value: JSON.stringify(entry),
      expiresAt: new Date(entry.expiresAt)
    })

    if (maxSize > 0) // Keep the newest non-expired queue entries. A queue overflow should drop
    // oldest pending messages rather than the message that just arrived.
    {
      await DB.execute(sql`
        DELETE FROM ${ChatStateQueues}
        WHERE ${ChatStateQueues.keyPrefix} = ${this.keyPrefix}
          AND ${ChatStateQueues.threadId} = ${threadId}
          AND ${ChatStateQueues.seq} IN (
            SELECT seq FROM ${ChatStateQueues}
            WHERE ${ChatStateQueues.keyPrefix} = ${this.keyPrefix}
              AND ${ChatStateQueues.threadId} = ${threadId}
              AND ${ChatStateQueues.expiresAt} > now()
            ORDER BY seq ASC
            OFFSET 0
            LIMIT GREATEST(
              (SELECT count(*) FROM ${ChatStateQueues}
               WHERE ${ChatStateQueues.keyPrefix} = ${this.keyPrefix}
                 AND ${ChatStateQueues.threadId} = ${threadId}
                 AND ${ChatStateQueues.expiresAt} > now()) - ${maxSize},
              0
            )
          )
      `)
    }

    return this.queueDepth(threadId)
  }

  async dequeue(threadId: string): Promise<QueueEntry | null> {
    this.ensureConnected()

    await DB.delete(ChatStateQueues).where(
      and(
        eq(ChatStateQueues.keyPrefix, this.keyPrefix),
        eq(ChatStateQueues.threadId, threadId),
        sql`${ChatStateQueues.expiresAt} <= now()`
      )
    )

    // Select and delete in one statement so two workers cannot pop the same
    // queued message under concurrent webhook delivery.
    const rows = await executeRows<{ value: string }>(sql`
      DELETE FROM ${ChatStateQueues}
      WHERE ${ChatStateQueues.keyPrefix} = ${this.keyPrefix}
        AND ${ChatStateQueues.threadId} = ${threadId}
        AND ${ChatStateQueues.seq} = (
          SELECT seq FROM ${ChatStateQueues}
          WHERE ${ChatStateQueues.keyPrefix} = ${this.keyPrefix}
            AND ${ChatStateQueues.threadId} = ${threadId}
            AND ${ChatStateQueues.expiresAt} > now()
          ORDER BY seq ASC
          LIMIT 1
        )
      RETURNING value
    `)

    const row = rows[0]
    return row ? (JSON.parse(row.value) as QueueEntry) : null
  }

  async queueDepth(threadId: string): Promise<number> {
    this.ensureConnected()

    const rows = await executeRows<{ depth: string | number }>(sql`
      SELECT count(*) as depth FROM ${ChatStateQueues}
      WHERE ${ChatStateQueues.keyPrefix} = ${this.keyPrefix}
        AND ${ChatStateQueues.threadId} = ${threadId}
        AND ${ChatStateQueues.expiresAt} > now()
    `)

    return Number(rows[0]?.depth ?? 0)
  }

  private ensureConnected(): void {
    if (!this.connected) throw new Error('BullXPostgresChatStateStore is not connected. Call connect() first.')
  }
}

/**
 * Creates BullX's single supported Chat Gateway state store.
 */
export function createBullXChatStateStore(
  options: BullXChatStateStoreOptions = {}
): BullXPostgresChatStateStore {
  return new BullXPostgresChatStateStore(options)
}

async function executeRows<T>(query: ReturnType<typeof sql>): Promise<T[]> {
  return (await DB.execute(query)) as unknown as T[]
}

function generateToken(): string {
  return `pg_${crypto.randomUUID()}`
}
