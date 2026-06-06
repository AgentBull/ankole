import { and, eq, sql } from 'drizzle-orm'
import { DB, jsonbParam } from '@/common/database'
import { ExternalGatewayOutbox, type JsonObject } from '@/common/db-schema'
import type { AgentResult } from '@/principals/agents/service'
import { UnsupportedChannelCapabilityError, parseMarkdown, requireOutboundCapability } from './core'
import { cardToFallbackText, isCardElement } from './core/cards'
import type { ExternalGatewayProjectionSink } from './core/projection'
import type { ExternalGatewayAdapter, ExternalGatewayRoomInput } from './core/events'

export type ExternalGatewayOutboxOperation =
  | 'post'
  | 'delete'
  | 'reaction_add'
  | 'reaction_remove'
  | 'modal'
  | 'card'
  | 'divider'

export interface ExternalGatewayOutboundIntent {
  finalPayload: JsonObject
  operation: ExternalGatewayOutboxOperation
  outboundKey: string
  providerRoomId: string
  providerThreadId: string
}

export interface DispatchExternalGatewayOutboundInput {
  adapter: ExternalGatewayAdapter
  agent: AgentResult
  bindingName: string
  intent: ExternalGatewayOutboundIntent
  projection: ExternalGatewayProjectionSink
  room: Record<string, unknown>
}

type ExternalGatewayOutboxKey = Pick<
  typeof ExternalGatewayOutbox.$inferSelect,
  'agentUid' | 'bindingName' | 'outboundKey'
>

/**
 * Executes provider-visible side effects requested by the agent.
 *
 * Outbox rows are the owner of provider delivery status. A failed provider call
 * is recorded here and returned to the runtime; it must not cause the inbound
 * event that produced the intent to be marked failed after the agent accepted it.
 */
export class DrizzleExternalGatewayOutbox {
  async dispatch(input: DispatchExternalGatewayOutboundInput): Promise<typeof ExternalGatewayOutbox.$inferSelect> {
    const row = await this.upsertPending(input)
    if (row.status === 'sent' || row.status === 'unsupported' || row.status === 'failed') return row

    const key = outboxKeyFromRow(row)
    if (input.intent.operation === 'delete') return this.dispatchDelete(key, input)
    if (input.intent.operation === 'reaction_add' || input.intent.operation === 'reaction_remove') {
      return this.dispatchReaction(key, input)
    }
    if (input.intent.operation === 'divider') return this.dispatchPostLike(key, input, 'divider')
    if (input.intent.operation === 'card') return this.dispatchPostLike(key, input, 'card')
    if (input.intent.operation !== 'post') return this.markUnsupported(key, `Unsupported operation: ${input.intent.operation}`)

    return this.dispatchPostLike(key, input, 'post')
  }

  private async dispatchPostLike(
    key: ExternalGatewayOutboxKey,
    input: DispatchExternalGatewayOutboundInput,
    operation: Extract<ExternalGatewayOutboxOperation, 'post' | 'divider' | 'card'>
  ): Promise<typeof ExternalGatewayOutbox.$inferSelect> {
    const postable = postableFromFinalPayload(input.intent.finalPayload, operation)
    if (postable === undefined) return this.markUnsupported(key, `Final ${operation} payload is not postable`)
    const text = fallbackTextFromFinalPayload(input.intent.finalPayload, operation)

    try {
      const postMessage = requireOutboundCapability(
        input.adapter,
        operation === 'post' ? 'post_message' : operation,
        input.adapter.postMessage?.bind(input.adapter)
      )
      const rawMessage = await postMessage(input.intent.providerThreadId, postable)
      const sent = await this.markSent(key, rawMessage.id)
      await projectVisibleOutbound({
        agent: input.agent,
        adapter: input.adapter,
        messageId: rawMessage.id,
        projection: input.projection,
        room: roomFromIntent(input.intent, input.room, input.adapter),
        raw: rawMessage.raw,
        text,
        threadId: rawMessage.threadId || input.intent.providerThreadId
      })
      return sent
    } catch (error) {
      if (error instanceof UnsupportedChannelCapabilityError) {
        return this.markUnsupported(key, error.message)
      }

      return this.markFailed(key, error)
    }
  }

  private async upsertPending(
    input: DispatchExternalGatewayOutboundInput
  ): Promise<typeof ExternalGatewayOutbox.$inferSelect> {
    const [inserted] = await DB.insert(ExternalGatewayOutbox)
      .values({
        agentUid: input.agent.agent.uid,
        bindingName: input.bindingName,
        providerRoomId: input.intent.providerRoomId,
        providerThreadId: input.intent.providerThreadId,
        outboundKey: input.intent.outboundKey,
        operation: input.intent.operation,
        finalPayload: jsonbParam(input.intent.finalPayload),
        status: 'pending'
      })
      .onConflictDoNothing()
      .returning()

    if (inserted) return inserted

    const [existing] = await DB.select()
      .from(ExternalGatewayOutbox)
      .where(
        and(
          eq(ExternalGatewayOutbox.agentUid, input.agent.agent.uid),
          eq(ExternalGatewayOutbox.bindingName, input.bindingName),
          eq(ExternalGatewayOutbox.outboundKey, input.intent.outboundKey)
        )
      )
      .limit(1)

    if (!existing) throw new ExternalGatewayOutboxError(`Failed to upsert outbox ${input.intent.outboundKey}`)
    return existing
  }

  private async markSent(
    key: ExternalGatewayOutboxKey,
    providerMessageId: string
  ): Promise<typeof ExternalGatewayOutbox.$inferSelect> {
    const [row] = await DB.update(ExternalGatewayOutbox)
      .set({
        status: 'sent',
        providerMessageId,
        safeError: null,
        updatedAt: sql`now()`
      })
      .where(outboxKeyWhere(key))
      .returning()

    if (!row) throw new ExternalGatewayOutboxError(`Failed to mark outbox ${key.outboundKey} sent`)
    return row
  }

  private async markUnsupported(
    key: ExternalGatewayOutboxKey,
    reason: string
  ): Promise<typeof ExternalGatewayOutbox.$inferSelect> {
    const [row] = await DB.update(ExternalGatewayOutbox)
      .set({
        status: 'unsupported',
        safeError: reason,
        updatedAt: sql`now()`
      })
      .where(outboxKeyWhere(key))
      .returning()

    if (!row) throw new ExternalGatewayOutboxError(`Failed to mark outbox ${key.outboundKey} unsupported`)
    return row
  }

  private async markFailed(
    key: ExternalGatewayOutboxKey,
    error: unknown
  ): Promise<typeof ExternalGatewayOutbox.$inferSelect> {
    const [row] = await DB.update(ExternalGatewayOutbox)
      .set({
        status: 'failed',
        safeError: error instanceof Error ? error.message : String(error),
        updatedAt: sql`now()`
      })
      .where(outboxKeyWhere(key))
      .returning()

    if (!row) throw new ExternalGatewayOutboxError(`Failed to mark outbox ${key.outboundKey} failed`)
    return row
  }

  private async dispatchDelete(
    key: ExternalGatewayOutboxKey,
    input: DispatchExternalGatewayOutboundInput
  ): Promise<typeof ExternalGatewayOutbox.$inferSelect> {
    const targetMessageId = targetMessageIdFromFinalPayload(input.intent.finalPayload)
    if (!targetMessageId) return this.markUnsupported(key, 'Delete payload must contain targetMessageId')

    try {
      const deleteMessage = requireOutboundCapability(
        input.adapter,
        'delete_message',
        input.adapter.deleteMessage?.bind(input.adapter)
      )
      await deleteMessage(input.intent.providerThreadId, targetMessageId)
      const sent = await this.markSent(key, targetMessageId)
      await input.projection.projectDelete({
        room: roomFromIntent(input.intent, input.room, input.adapter),
        messageId: targetMessageId
      })
      return sent
    } catch (error) {
      if (error instanceof UnsupportedChannelCapabilityError) {
        return this.markUnsupported(key, error.message)
      }

      return this.markFailed(key, error)
    }
  }

  private async dispatchReaction(
    key: ExternalGatewayOutboxKey,
    input: DispatchExternalGatewayOutboundInput
  ): Promise<typeof ExternalGatewayOutbox.$inferSelect> {
    const targetMessageId = targetMessageIdFromFinalPayload(input.intent.finalPayload)
    if (!targetMessageId) return this.markUnsupported(key, 'Reaction payload must contain targetMessageId')

    const emojiValue = emojiFromFinalPayload(input.intent.finalPayload)
    if (emojiValue === undefined) return this.markUnsupported(key, 'Reaction payload must contain emoji')

    const added = input.intent.operation === 'reaction_add'

    try {
      if (added) {
        const addReaction = requireOutboundCapability(
          input.adapter,
          'add_reaction',
          input.adapter.addReaction?.bind(input.adapter)
        )
        await addReaction(input.intent.providerThreadId, targetMessageId, emojiValue)
      } else {
        const removeReaction = requireOutboundCapability(
          input.adapter,
          'remove_reaction',
          input.adapter.removeReaction?.bind(input.adapter)
        )
        await removeReaction(input.intent.providerThreadId, targetMessageId, emojiValue)
      }

      const sent = await this.markSent(key, targetMessageId)
      await input.projection.projectReaction({
        added,
        emoji: emojiValue,
        messageId: targetMessageId,
        raw: input.intent.finalPayload,
        rawEmoji: typeof emojiValue === 'string' ? emojiValue : undefined,
        room: roomFromIntent(input.intent, input.room, input.adapter),
        threadId: input.intent.providerThreadId,
        user: {
          userId: 'self',
          userName: input.adapter.userName || input.agent.agent.uid,
          fullName: input.adapter.userName || input.agent.agent.uid,
          isBot: true,
          isMe: true
        }
      })
      return sent
    } catch (error) {
      if (error instanceof UnsupportedChannelCapabilityError) {
        return this.markUnsupported(key, error.message)
      }

      return this.markFailed(key, error)
    }
  }
}

export const externalGatewayOutbox = new DrizzleExternalGatewayOutbox()

function outboxKeyFromRow(row: ExternalGatewayOutboxKey): ExternalGatewayOutboxKey {
  return {
    agentUid: row.agentUid,
    bindingName: row.bindingName,
    outboundKey: row.outboundKey
  }
}

function outboxKeyWhere(key: ExternalGatewayOutboxKey) {
  return and(
    eq(ExternalGatewayOutbox.agentUid, key.agentUid),
    eq(ExternalGatewayOutbox.bindingName, key.bindingName),
    eq(ExternalGatewayOutbox.outboundKey, key.outboundKey)
  )
}

async function projectVisibleOutbound(input: {
  adapter: ExternalGatewayAdapter
  agent: AgentResult
  messageId: string
  projection: ExternalGatewayProjectionSink
  room: Required<Pick<ExternalGatewayRoomInput, 'id'>> & ExternalGatewayRoomInput
  raw: unknown
  text: string
  threadId: string
}): Promise<void> {
  await input.projection.projectMessage({
    room: input.room,
    message: {
      id: input.messageId,
      threadId: input.threadId,
      text: input.text,
      formatted: parseMarkdown(input.text),
      raw: input.raw,
      author: {
        userId: 'self',
        userName: input.adapter.userName || input.agent.agent.uid,
        fullName: input.adapter.userName || input.agent.agent.uid,
        isBot: true,
        isMe: true
      },
      metadata: {
        dateSent: new Date()
      },
      attachments: [],
      links: []
    }
  })
}

function postableFromFinalPayload(
  payload: JsonObject,
  operation: Extract<ExternalGatewayOutboxOperation, 'post' | 'divider' | 'card'>
): unknown {
  /*
   * The gateway owns only a small operation switch. Provider-native rendering
   * remains adapter-owned; for card/divider this function prepares the minimal
   * postable object the adapter already declares it can handle.
   */
  if (operation === 'divider') return { ...payload, type: 'divider' }
  if (operation === 'card') {
    if ('card' in payload) return payload
    if (isCardElement(payload)) return payload
    return undefined
  }

  if (typeof payload.text === 'string') return payload.text
  if (typeof payload.markdown === 'string' || typeof payload.raw === 'string' || 'ast' in payload || 'card' in payload) {
    return payload
  }

  return undefined
}

function fallbackTextFromFinalPayload(
  payload: JsonObject,
  operation: Extract<ExternalGatewayOutboxOperation, 'post' | 'divider' | 'card'>
): string {
  if (typeof payload.text === 'string') return payload.text
  if (typeof payload.markdown === 'string') return payload.markdown
  if (typeof payload.fallbackText === 'string') return payload.fallbackText
  if (typeof payload.raw === 'string') return payload.raw
  if (operation === 'divider') return '[divider]'
  const card = 'card' in payload ? payload.card : payload
  if (isCardElement(card)) return cardToFallbackText(card)

  return JSON.stringify(payload)
}

function emojiFromFinalPayload(payload: JsonObject): unknown {
  for (const key of ['emoji', 'rawEmoji', 'emojiType', 'reaction']) {
    const value = payload[key]
    if (value !== undefined && value !== null) return value
  }

  return undefined
}

function targetMessageIdFromFinalPayload(payload: JsonObject): string | undefined {
  for (const key of ['targetMessageId', 'targetProviderMessageId', 'providerMessageId', 'messageId']) {
    const value = payload[key]
    if (typeof value === 'string' && value.length > 0) return value
  }

  return undefined
}

function roomFromIntent(
  intent: ExternalGatewayOutboundIntent,
  room: Record<string, unknown>,
  adapter: ExternalGatewayAdapter
): Required<Pick<ExternalGatewayRoomInput, 'id'>> & ExternalGatewayRoomInput {
  return {
    id: intent.providerRoomId,
    isDM: typeof room.isDM === 'boolean' ? room.isDM : (adapter.isDM?.(intent.providerThreadId) ?? false),
    metadata: typeof room.metadata === 'object' && room.metadata !== null && !Array.isArray(room.metadata) ? room.metadata as JsonObject : {},
    name: typeof room.name === 'string' ? room.name : null,
    raw: null,
    roomVisibility:
      typeof room.roomVisibility === 'string'
        ? room.roomVisibility
        : (adapter.getChannelVisibility?.(intent.providerThreadId) ?? 'unknown')
  }
}

export class ExternalGatewayOutboxError extends Error {
  constructor(message: string) {
    super(message)
    this.name = 'ExternalGatewayOutboxError'
  }
}
