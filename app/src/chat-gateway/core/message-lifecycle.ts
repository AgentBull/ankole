import type { Message } from './message'
import { ms } from '@pleisto/active-support'
import { and, eq, gt, isNull, or, sql } from 'drizzle-orm'
import type {
  BullXChatGatewayInboundMessageMutationResult,
  BullXChatGatewayMessageLifecycleReplyAction
} from '@agentbull/bullx-sdk/plugins'
import { DB, type QueryExecutor } from '@/common/database'
import { ChatMessages, ChatStateCache } from '@/common/db-schema'
import { echoPlaceholderText } from './echo-text'
import {
  chatGatewayProjectionSink,
  type ChatGatewayProjectionSink,
  type ChatGatewayProjectionThread
} from './projection'

export type ChatGatewayMessageLifecycleResult = BullXChatGatewayInboundMessageMutationResult
export type ChatGatewayMessageLifecycleReplyAction = BullXChatGatewayMessageLifecycleReplyAction

export interface ChatGatewayMessageLifecycleRecordReplyInput {
  agentUid: string
  inboundChannelId: string
  inboundThreadId: string
  inboundMessageId: string
  replyThreadId: string
  replyMessageId: string
}

export interface ChatGatewayMessageLifecycleRecordReplyResult {
  /**
   * `false` means the inbound message already has a terminal tombstone. The
   * caller should recall the just-posted reply instead of storing a new reply
   * link for a deleted turn.
   */
  recorded: boolean
}

export interface ChatGatewayMessageLifecycleMarkReplyReconciledInput extends ChatGatewayMessageLifecycleRecordReplyInput {}

export interface ChatGatewayMessageLifecycleUpdateInput<TRawMessage = unknown> {
  agentUid: string
  channelId: string
  messageId: string
  thread: ChatGatewayProjectionThread
  message: Message<TRawMessage>
}

export interface ChatGatewayMessageLifecycleDeleteInput {
  agentUid: string
  channelId: string
  messageId: string
}

export interface ChatGatewayMessageLifecycleForgetReplyInput extends ChatGatewayMessageLifecycleDeleteInput {}

/**
 * Host-owned bridge for chat-platform edit/delete events.
 *
 * Chat SDK processes ordinary inbound messages and BullX replies in separate
 * calls. External platforms such as Lark later identify edits/deletes by the
 * original user message id, so the host must remember which BullX reply was
 * created for that inbound message. The mapping lives in `chat_state_cache`
 * under the same agent key prefix as Chat SDK runtime state because it is
 * coordination state, not a long-term chat transcript or identity binding.
 */
export interface ChatGatewayMessageLifecycleSink {
  isDeleted(input: ChatGatewayMessageLifecycleDeleteInput): Promise<boolean>
  /**
   * Records the BullX-authored reply for later edit/delete lifecycle handling.
   *
   * The write is tombstone-aware: if a recall/delete already won the race, this
   * returns `recorded: false` so the caller can immediately recall the reply it
   * just posted.
   */
  recordReply(input: ChatGatewayMessageLifecycleRecordReplyInput): Promise<ChatGatewayMessageLifecycleRecordReplyResult>
  /**
   * Projects the edited inbound message as IM latest-state and returns any
   * BullX reply side effect still needed for that latest-state.
   *
   * The projection is intentionally independent from reply side effects:
   * `chat_messages` is BullX's long-term mirror of what users see in IM, while
   * reply-link state tracks whether BullX's own reply has caught up.
   */
  updateInboundMessage<TRawMessage = unknown>(
    input: ChatGatewayMessageLifecycleUpdateInput<TRawMessage>
  ): Promise<ChatGatewayMessageLifecycleResult>
  /**
   * Marks the BullX reply as reconciled with the current projected inbound
   * visible state after the external adapter has successfully edited it.
   */
  markReplyReconciled(
    input: ChatGatewayMessageLifecycleMarkReplyReconciledInput
  ): Promise<ChatGatewayMessageLifecycleRecordReplyResult>
  /**
   * Marks an inbound message as terminal and returns any BullX reply target.
   *
   * This deliberately does not consume the reply link. The caller removes that
   * link with `forgetReply()` only after the external platform confirms recall,
   * so transient provider failures stay retryable.
   */
  deleteInboundMessage(input: ChatGatewayMessageLifecycleDeleteInput): Promise<ChatGatewayMessageLifecycleResult>
  forgetReply(input: ChatGatewayMessageLifecycleForgetReplyInput): Promise<void>
}

interface ReplyLink {
  inboundChannelId: string
  inboundThreadId: string
  inboundMessageId: string
  replyThreadId: string
  replyMessageId: string
  reconciledIsMention?: boolean
  reconciledText?: string | null
}

const DELETED_TOMBSTONE_TTL_MS = ms('24h')

export class DrizzleChatGatewayMessageLifecycleSink implements ChatGatewayMessageLifecycleSink {
  constructor(private readonly projection: ChatGatewayProjectionSink = chatGatewayProjectionSink) {}

  async isDeleted(input: ChatGatewayMessageLifecycleDeleteInput): Promise<boolean> {
    return isDeletedTombstonePresent(input.agentUid, input.channelId, input.messageId)
  }

  async recordReply(
    input: ChatGatewayMessageLifecycleRecordReplyInput
  ): Promise<ChatGatewayMessageLifecycleRecordReplyResult> {
    return upsertReplyLinkFromProjectedState(input)
  }

  async forgetReply(input: ChatGatewayMessageLifecycleForgetReplyInput): Promise<void> {
    await consumeReplyLink(input.agentUid, input.channelId, input.messageId)
  }

  async updateInboundMessage<TRawMessage = unknown>(
    input: ChatGatewayMessageLifecycleUpdateInput<TRawMessage>
  ): Promise<ChatGatewayMessageLifecycleResult> {
    if (await this.isDeleted(input)) return { handled: true }

    const existing = await findProjectedMessage(input.channelId, input.messageId)
    // If BullX never saw the original message, this edit is the first admissible
    // version of that platform message. Let normal message routing decide
    // whether it is addressed or ambient.
    if (!existing) return { handled: false }

    const nextText = input.message.text ?? null
    const nextIsMention = input.message.isMention ?? false
    const previous = { text: existing.text, isMention: existing.isMention }

    await this.projection.projectMessage({
      thread: input.thread,
      message: input.message
    })

    const reply = await findReplyLink(input.agentUid, input.channelId, input.messageId)
    if (!reply) {
      return isLatestStateAddressed(input.thread, nextIsMention)
        ? {
            handled: true,
            previous,
            reply: {
              kind: 'create',
              threadId: input.thread.id,
              text: echoPlaceholderText(input.agentUid, input.message.text)
            }
          }
        : { handled: true, previous }
    }

    if (!isLatestStateAddressed(input.thread, nextIsMention)) {
      return {
        handled: true,
        previous,
        reply: {
          kind: 'delete',
          threadId: reply.replyThreadId,
          messageId: reply.replyMessageId
        }
      }
    }

    const replyIsStale = reply.reconciledText !== nextText || reply.reconciledIsMention !== nextIsMention
    if (!replyIsStale) return { handled: true, previous }

    return {
      handled: true,
      previous,
      reply: {
        kind: 'edit',
        threadId: reply.replyThreadId,
        messageId: reply.replyMessageId,
        text: echoPlaceholderText(input.agentUid, input.message.text)
      }
    }
  }

  async markReplyReconciled(
    input: ChatGatewayMessageLifecycleMarkReplyReconciledInput
  ): Promise<ChatGatewayMessageLifecycleRecordReplyResult> {
    return upsertReplyLinkFromProjectedState(input)
  }

  async deleteInboundMessage(
    input: ChatGatewayMessageLifecycleDeleteInput
  ): Promise<ChatGatewayMessageLifecycleResult> {
    const reply = await DB.transaction(async tx => {
      await tx
        .delete(ChatMessages)
        .where(and(eq(ChatMessages.channelId, input.channelId), eq(ChatMessages.messageId, input.messageId)))

      await recordDeletedTombstoneWithDb(tx, input.agentUid, input.channelId, input.messageId)

      return findReplyLinkWithDb(tx, input.agentUid, input.channelId, input.messageId)
    })

    return {
      handled: true,
      reply: reply
        ? {
            kind: 'delete',
            threadId: reply.replyThreadId,
            messageId: reply.replyMessageId
          }
        : undefined
    }
  }
}

export const chatGatewayMessageLifecycleSink: ChatGatewayMessageLifecycleSink =
  new DrizzleChatGatewayMessageLifecycleSink()

async function findProjectedMessage(
  channelId: string,
  messageId: string
): Promise<{ text: string | null; isMention: boolean } | undefined> {
  return findProjectedMessageWithDb(DB, channelId, messageId)
}

async function findProjectedMessageWithDb(
  db: QueryExecutor,
  channelId: string,
  messageId: string
): Promise<{ text: string | null; isMention: boolean } | undefined> {
  const rows = await db
    .select({ text: ChatMessages.text, isMention: ChatMessages.isMention })
    .from(ChatMessages)
    .where(and(eq(ChatMessages.channelId, channelId), eq(ChatMessages.messageId, messageId)))
    .limit(1)

  return rows[0]
}

async function upsertReplyLinkFromProjectedState(
  input: ChatGatewayMessageLifecycleRecordReplyInput
): Promise<ChatGatewayMessageLifecycleRecordReplyResult> {
  return DB.transaction(async tx => {
    const deleted = await isDeletedTombstonePresentWithDb(
      tx,
      input.agentUid,
      input.inboundChannelId,
      input.inboundMessageId
    )
    if (deleted) return { recorded: false }

    const projected = await findProjectedMessageWithDb(tx, input.inboundChannelId, input.inboundMessageId)
    if (!projected) return { recorded: false }

    const link: ReplyLink = {
      inboundChannelId: input.inboundChannelId,
      inboundThreadId: input.inboundThreadId,
      inboundMessageId: input.inboundMessageId,
      replyThreadId: input.replyThreadId,
      replyMessageId: input.replyMessageId,
      reconciledText: projected.text,
      reconciledIsMention: projected.isMention
    }

    await tx
      .insert(ChatStateCache)
      .values({
        keyPrefix: stateKeyPrefix(input.agentUid),
        cacheKey: replyLinkCacheKey(input.inboundChannelId, input.inboundMessageId),
        value: JSON.stringify(link),
        expiresAt: null
      })
      .onConflictDoUpdate({
        target: [ChatStateCache.keyPrefix, ChatStateCache.cacheKey],
        set: {
          value: sql`EXCLUDED.value`,
          expiresAt: null,
          updatedAt: sql`now()`
        }
      })

    return { recorded: true }
  })
}

async function findReplyLink(agentUid: string, channelId: string, messageId: string): Promise<ReplyLink | undefined> {
  return findReplyLinkWithDb(DB, agentUid, channelId, messageId)
}

async function findReplyLinkWithDb(
  db: QueryExecutor,
  agentUid: string,
  channelId: string,
  messageId: string
): Promise<ReplyLink | undefined> {
  const rows = await db
    .select({ value: ChatStateCache.value })
    .from(ChatStateCache)
    .where(
      and(
        eq(ChatStateCache.keyPrefix, stateKeyPrefix(agentUid)),
        eq(ChatStateCache.cacheKey, replyLinkCacheKey(channelId, messageId))
      )
    )
    .limit(1)

  return parseReplyLink(rows[0]?.value)
}

async function consumeReplyLink(
  agentUid: string,
  channelId: string,
  messageId: string
): Promise<ReplyLink | undefined> {
  const keyPrefix = stateKeyPrefix(agentUid)
  const cacheKey = replyLinkCacheKey(channelId, messageId)
  const rows = await DB.delete(ChatStateCache)
    .where(and(eq(ChatStateCache.keyPrefix, keyPrefix), eq(ChatStateCache.cacheKey, cacheKey)))
    .returning({ value: ChatStateCache.value })

  return parseReplyLink(rows[0]?.value)
}

async function recordDeletedTombstoneWithDb(
  db: QueryExecutor,
  agentUid: string,
  channelId: string,
  messageId: string
): Promise<void> {
  await db
    .insert(ChatStateCache)
    .values({
      keyPrefix: stateKeyPrefix(agentUid),
      cacheKey: deletedTombstoneCacheKey(channelId, messageId),
      value: JSON.stringify({ deletedAt: new Date().toISOString() }),
      expiresAt: new Date(Date.now() + DELETED_TOMBSTONE_TTL_MS)
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

async function isDeletedTombstonePresent(agentUid: string, channelId: string, messageId: string): Promise<boolean> {
  return isDeletedTombstonePresentWithDb(DB, agentUid, channelId, messageId)
}

async function isDeletedTombstonePresentWithDb(
  db: QueryExecutor,
  agentUid: string,
  channelId: string,
  messageId: string
): Promise<boolean> {
  const rows = await db
    .select({ cacheKey: ChatStateCache.cacheKey })
    .from(ChatStateCache)
    .where(
      and(
        eq(ChatStateCache.keyPrefix, stateKeyPrefix(agentUid)),
        eq(ChatStateCache.cacheKey, deletedTombstoneCacheKey(channelId, messageId)),
        or(isNull(ChatStateCache.expiresAt), gt(ChatStateCache.expiresAt, new Date()))
      )
    )
    .limit(1)

  return rows.length > 0
}

function parseReplyLink(value: string | undefined): ReplyLink | undefined {
  if (!value) return undefined

  try {
    const parsed = JSON.parse(value) as Partial<ReplyLink>
    if (
      typeof parsed.inboundChannelId === 'string' &&
      typeof parsed.inboundThreadId === 'string' &&
      typeof parsed.inboundMessageId === 'string' &&
      typeof parsed.replyThreadId === 'string' &&
      typeof parsed.replyMessageId === 'string'
    ) {
      return {
        inboundChannelId: parsed.inboundChannelId,
        inboundThreadId: parsed.inboundThreadId,
        inboundMessageId: parsed.inboundMessageId,
        replyThreadId: parsed.replyThreadId,
        replyMessageId: parsed.replyMessageId,
        reconciledText:
          typeof parsed.reconciledText === 'string' || parsed.reconciledText === null
            ? parsed.reconciledText
            : undefined,
        reconciledIsMention: typeof parsed.reconciledIsMention === 'boolean' ? parsed.reconciledIsMention : undefined
      }
    }
  } catch {
    return undefined
  }

  return undefined
}

function stateKeyPrefix(agentUid: string): string {
  return `bullx-agent:${agentUid}`
}

function replyLinkCacheKey(channelId: string, messageId: string): string {
  return `message-lifecycle.reply-link:${encodeURIComponent(channelId)}:${encodeURIComponent(messageId)}`
}

function deletedTombstoneCacheKey(channelId: string, messageId: string): string {
  return `message-lifecycle.deleted:${encodeURIComponent(channelId)}:${encodeURIComponent(messageId)}`
}

function isLatestStateAddressed(thread: ChatGatewayProjectionThread, isMention: boolean): boolean {
  return thread.channel.isDM || isMention
}
