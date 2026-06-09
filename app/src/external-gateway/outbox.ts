import { genericHash } from '@agentbull/bullx-native-addons'
import { match } from '@pleisto/active-support'
import { and, asc, eq, sql } from 'drizzle-orm'
import { DB, jsonbParam } from '@/common/database'
import { ExternalGatewayOutbox, type JsonObject } from '@/common/db-schema'
import type { AgentResult } from '@/principals/agents/service'
import { adapterSupportsCapability, requireOutboundCapability } from './core/capabilities'
import { UnsupportedChannelCapabilityError } from './core/errors'
import { parseMarkdown } from './core/markdown'
import { cardPayloadFallbackText, isExternalGatewayCardPayload } from './interactive-output'
import type { ExternalGatewayProjectionSink } from './core/projection'
import type { ExternalGatewayAdapter, ExternalGatewayOutboundOptions, ExternalGatewayRoomInput } from './core/events'

export type ExternalGatewayOutboxOperation =
  | 'post'
  | 'reply'
  | 'edit'
  | 'delete'
  | 'reaction_add'
  | 'reaction_remove'
  | 'modal'
  | 'card'
  | 'divider'

export interface ExternalGatewayOutboundIntent {
  /**
   * Operation-specific payload. The column stays `jsonb`; producers set the
   * canonical keys per operation so the dispatcher does not probe ad-hoc aliases:
   * - post / reply : `{ text }` or `{ markdown }`
   * - card         : `{ kind: 'interactive_output', output }` or `{ kind: 'lark_native_card', card, fallbackText }`
   * - divider      : `{ kind: 'control_notice', text, fallbackText? }`
   * - edit         : `{ targetOutboundKey, text|interactive_output|lark_native_card, ... }` (or `intent.providerMessageId`)
   * - delete       : `{ targetMessageId }` or `{ targetOutboundKey }`
   * - reaction_*   : `{ targetMessageId, emoji }`
   */
  finalPayload: JsonObject
  idempotencyKey?: string
  operation: ExternalGatewayOutboxOperation
  outboundKey: string
  providerMessageId?: string | null
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

const IDEMPOTENT_SEND_REPLAY_WINDOW_MS = 55 * 60 * 1000

/**
 * Executes provider-visible side effects requested by the agent.
 *
 * Outbox rows are the owner of provider delivery status. A failed provider call
 * is recorded here and returned to the runtime; it must not cause the inbound
 * event that produced the intent to be marked failed after the agent accepted it.
 */
export class DrizzleExternalGatewayOutbox {
  async enqueuePending(input: {
    agentUid: string
    bindingName: string
    intent: ExternalGatewayOutboundIntent
  }): Promise<typeof ExternalGatewayOutbox.$inferSelect> {
    return this.upsertPending(input.agentUid, input.bindingName, input.intent)
  }

  async enqueuePendingMany(input: {
    agentUid: string
    bindingName: string
    intents: readonly ExternalGatewayOutboundIntent[]
  }): Promise<void> {
    for (const intent of input.intents) await this.enqueuePending({ ...input, intent })
  }

  async dispatch(input: DispatchExternalGatewayOutboundInput): Promise<typeof ExternalGatewayOutbox.$inferSelect> {
    const row = await this.upsertPending(input.agent.agent.uid, input.bindingName, input.intent)
    if (row.status === 'sent' || row.status === 'unsupported' || row.status === 'failed') return row

    return this.dispatchRow(row, input)
  }

  async dispatchPendingForBinding(input: Omit<DispatchExternalGatewayOutboundInput, 'intent'>): Promise<void> {
    const rows = await DB.select()
      .from(ExternalGatewayOutbox)
      .where(
        and(
          eq(ExternalGatewayOutbox.agentUid, input.agent.agent.uid),
          eq(ExternalGatewayOutbox.bindingName, input.bindingName),
          eq(ExternalGatewayOutbox.status, 'pending'),
          sql`${ExternalGatewayOutbox.retryCount} < 5`,
          sql`(${ExternalGatewayOutbox.lastAttemptAt} is null or ${ExternalGatewayOutbox.lastAttemptAt} < now() - (interval '2 seconds' * greatest(1, ${ExternalGatewayOutbox.retryCount})))`
        )
      )
      .orderBy(asc(ExternalGatewayOutbox.createdAt))
      .limit(50)

    for (const row of rows) {
      await this.dispatchRow(row, {
        ...input,
        intent: intentFromRow(row)
      })
    }
  }

  private async dispatchRow(
    row: typeof ExternalGatewayOutbox.$inferSelect,
    input: DispatchExternalGatewayOutboundInput
  ): Promise<typeof ExternalGatewayOutbox.$inferSelect> {
    const key = outboxKeyFromRow(row)

    if (row.recoveryState === 'send_attempt_started' && row.providerMessageId) {
      const reconciled = await this.tryReconcileExisting(row, input)
      if (reconciled) return reconciled
    }

    if (
      row.recoveryState === 'send_attempt_started' &&
      !row.providerMessageId &&
      adapterSupportsCapability(input.adapter, 'outbound', 'outbound_idempotency') &&
      row.platformSendStartedAt &&
      Date.now() - row.platformSendStartedAt.getTime() > IDEMPOTENT_SEND_REPLAY_WINDOW_MS
    ) {
      return this.markUnknownAfterSend(key, 'Previous send attempt is outside the idempotency replay window')
    }

    if (
      row.recoveryState === 'send_attempt_started' &&
      !adapterSupportsCapability(input.adapter, 'outbound', 'outbound_idempotency')
    ) {
      return this.markUnknownAfterSend(key, 'Previous send attempt started and adapter cannot prove idempotency')
    }

    await this.markSendAttemptStarted(key)

    if (input.intent.operation === 'delete') return this.dispatchDelete(key, input)
    if (input.intent.operation === 'edit') return this.dispatchEdit(key, input)
    if (input.intent.operation === 'reaction_add' || input.intent.operation === 'reaction_remove') {
      return this.dispatchReaction(key, input)
    }
    if (input.intent.operation === 'divider') return this.dispatchPostLike(key, input, 'divider')
    if (input.intent.operation === 'card') return this.dispatchPostLike(key, input, 'card')
    if (input.intent.operation !== 'post' && input.intent.operation !== 'reply') {
      return this.markUnsupported(key, `Unsupported operation: ${input.intent.operation}`)
    }

    return this.dispatchPostLike(key, input, input.intent.operation)
  }

  private async dispatchPostLike(
    key: ExternalGatewayOutboxKey,
    input: DispatchExternalGatewayOutboundInput,
    operation: Extract<ExternalGatewayOutboxOperation, 'post' | 'reply' | 'divider' | 'card'>
  ): Promise<typeof ExternalGatewayOutbox.$inferSelect> {
    const postable = postableFromFinalPayload(input.intent.finalPayload, operation)
    if (postable === undefined) return this.markUnsupported(key, `Final ${operation} payload is not postable`)
    const text = fallbackTextFromFinalPayload(input.intent.finalPayload, operation)

    try {
      const postMessage = requireOutboundCapability(
        input.adapter,
        match(operation)
          .with('reply', () => 'reply_message' as const)
          .with('post', () => 'post_message' as const)
          .otherwise(value => value),
        input.adapter.postMessage?.bind(input.adapter)
      )
      const rawMessage = await postMessage(input.intent.providerThreadId, postable, outboundOptions(input.intent))
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

      return this.markProviderFailure(key, input.adapter, error)
    }
  }

  private async upsertPending(
    agentUid: string,
    bindingName: string,
    intent: ExternalGatewayOutboundIntent
  ): Promise<typeof ExternalGatewayOutbox.$inferSelect> {
    const [inserted] = await DB.insert(ExternalGatewayOutbox)
      .values({
        agentUid,
        bindingName,
        providerRoomId: intent.providerRoomId,
        providerThreadId: intent.providerThreadId,
        outboundKey: intent.outboundKey,
        operation: intent.operation,
        finalPayload: jsonbParam(intent.finalPayload),
        providerMessageId: intent.providerMessageId ?? null,
        idempotencyKey: intent.idempotencyKey ?? idempotencyKeyFromOutboundKey(intent.outboundKey),
        status: 'pending',
        recoveryState: 'not_started'
      })
      .onConflictDoNothing()
      .returning()

    if (inserted) return inserted

    const [existing] = await DB.select()
      .from(ExternalGatewayOutbox)
      .where(
        and(
          eq(ExternalGatewayOutbox.agentUid, agentUid),
          eq(ExternalGatewayOutbox.bindingName, bindingName),
          eq(ExternalGatewayOutbox.outboundKey, intent.outboundKey)
        )
      )
      .limit(1)

    if (!existing) throw new ExternalGatewayOutboxError(`Failed to upsert outbox ${intent.outboundKey}`)
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
        recoveryState: 'not_started',
        safeError: null,
        lastError: null,
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
        lastError: reason,
        updatedAt: sql`now()`
      })
      .where(outboxKeyWhere(key))
      .returning()

    if (!row) throw new ExternalGatewayOutboxError(`Failed to mark outbox ${key.outboundKey} unsupported`)
    return row
  }

  private async markProviderFailure(
    key: ExternalGatewayOutboxKey,
    adapter: ExternalGatewayAdapter,
    error: unknown
  ): Promise<typeof ExternalGatewayOutbox.$inferSelect> {
    const reason = error instanceof Error ? error.message : String(error)
    if (adapterSupportsCapability(adapter, 'outbound', 'outbound_idempotency')) {
      const [row] = await DB.update(ExternalGatewayOutbox)
        .set({
          status: 'pending',
          retryCount: sql`${ExternalGatewayOutbox.retryCount} + 1`,
          lastAttemptAt: new Date(),
          lastError: reason,
          safeError: reason,
          updatedAt: sql`now()`
        })
        .where(outboxKeyWhere(key))
        .returning()
      if (!row) throw new ExternalGatewayOutboxError(`Failed to keep outbox ${key.outboundKey} pending`)
      return row
    }

    return this.markUnknownAfterSend(key, reason)
  }

  private async markUnknownAfterSend(
    key: ExternalGatewayOutboxKey,
    reason: string
  ): Promise<typeof ExternalGatewayOutbox.$inferSelect> {
    const [row] = await DB.update(ExternalGatewayOutbox)
      .set({
        status: 'failed',
        recoveryState: 'unknown_after_send',
        safeError: reason,
        lastError: reason,
        updatedAt: sql`now()`
      })
      .where(outboxKeyWhere(key))
      .returning()

    if (!row) throw new ExternalGatewayOutboxError(`Failed to mark outbox ${key.outboundKey} failed`)
    return row
  }

  private async markSendAttemptStarted(key: ExternalGatewayOutboxKey): Promise<void> {
    await DB.update(ExternalGatewayOutbox)
      .set({
        platformSendStartedAt: new Date(),
        recoveryState: 'send_attempt_started',
        lastAttemptAt: new Date(),
        updatedAt: sql`now()`
      })
      .where(outboxKeyWhere(key))
  }

  private async dispatchDelete(
    key: ExternalGatewayOutboxKey,
    input: DispatchExternalGatewayOutboundInput
  ): Promise<typeof ExternalGatewayOutbox.$inferSelect> {
    const targetMessageId =
      targetMessageIdFromFinalPayload(input.intent.finalPayload) ??
      (await this.providerMessageIdFromTargetOutboundKey(key, input.intent.finalPayload))
    if (!targetMessageId) return this.markUnsupported(key, 'Delete payload must contain targetMessageId')

    try {
      const deleteMessage = requireOutboundCapability(
        input.adapter,
        'delete_message',
        input.adapter.deleteMessage?.bind(input.adapter)
      )
      await deleteMessage(
        input.intent.providerThreadId,
        targetMessageId,
        outboundOptions(input.intent, targetMessageId)
      )
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

      return this.markProviderFailure(key, input.adapter, error)
    }
  }

  private async dispatchEdit(
    key: ExternalGatewayOutboxKey,
    input: DispatchExternalGatewayOutboundInput
  ): Promise<typeof ExternalGatewayOutbox.$inferSelect> {
    const targetMessageId =
      targetMessageIdFromFinalPayload(input.intent.finalPayload) ??
      input.intent.providerMessageId ??
      (await this.providerMessageIdFromTargetOutboundKey(key, input.intent.finalPayload))
    if (!targetMessageId) return this.markUnsupported(key, 'Edit payload must contain targetMessageId')
    const postable = postableFromEditPayload(input.intent.finalPayload)
    if (postable === undefined) return this.markUnsupported(key, 'Edit payload is not postable')

    try {
      const editMessage = requireOutboundCapability(
        input.adapter,
        'edit_message',
        input.adapter.editMessage?.bind(input.adapter)
      )
      const rawMessage = await editMessage(
        input.intent.providerThreadId,
        targetMessageId,
        postable,
        outboundOptions(input.intent, targetMessageId)
      )
      const sent = await this.markSent(key, rawMessage.id || targetMessageId)
      await projectVisibleOutbound({
        agent: input.agent,
        adapter: input.adapter,
        messageId: rawMessage.id || targetMessageId,
        projection: input.projection,
        room: roomFromIntent(input.intent, input.room, input.adapter),
        raw: rawMessage.raw,
        text: fallbackTextFromFinalPayload(input.intent.finalPayload, 'post'),
        threadId: rawMessage.threadId || input.intent.providerThreadId
      })
      return sent
    } catch (error) {
      if (error instanceof UnsupportedChannelCapabilityError) return this.markUnsupported(key, error.message)
      return this.markProviderFailure(key, input.adapter, error)
    }
  }

  private async providerMessageIdFromTargetOutboundKey(
    key: ExternalGatewayOutboxKey,
    payload: JsonObject
  ): Promise<string | undefined> {
    const targetOutboundKey = payload.targetOutboundKey
    if (typeof targetOutboundKey !== 'string' || targetOutboundKey.length === 0) return undefined
    const [row] = await DB.select()
      .from(ExternalGatewayOutbox)
      .where(
        and(
          eq(ExternalGatewayOutbox.agentUid, key.agentUid),
          eq(ExternalGatewayOutbox.bindingName, key.bindingName),
          eq(ExternalGatewayOutbox.outboundKey, targetOutboundKey)
        )
      )
      .limit(1)
    return row?.providerMessageId ?? undefined
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

      return this.markProviderFailure(key, input.adapter, error)
    }
  }

  private async tryReconcileExisting(
    row: typeof ExternalGatewayOutbox.$inferSelect,
    input: DispatchExternalGatewayOutboundInput
  ): Promise<typeof ExternalGatewayOutbox.$inferSelect | undefined> {
    if (!row.providerMessageId) return undefined
    if (!adapterSupportsCapability(input.adapter, 'outbound', 'outbound_reconciliation')) return undefined
    if (!input.adapter.reconcileMessage) return undefined
    const key = outboxKeyFromRow(row)
    try {
      const reconciled = await input.adapter.reconcileMessage(
        row.providerThreadId,
        row.providerMessageId,
        outboundOptions(intentFromRow(row), row.providerMessageId)
      )
      if (reconciled.exists && !reconciled.deleted) return this.markSent(key, reconciled.providerMessageId)
      return undefined
    } catch {
      return undefined
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

function intentFromRow(row: typeof ExternalGatewayOutbox.$inferSelect): ExternalGatewayOutboundIntent {
  return {
    finalPayload: row.finalPayload,
    idempotencyKey: row.idempotencyKey ?? undefined,
    operation: row.operation as ExternalGatewayOutboxOperation,
    outboundKey: row.outboundKey,
    providerMessageId: row.providerMessageId,
    providerRoomId: row.providerRoomId,
    providerThreadId: row.providerThreadId
  }
}

function outboundOptions(
  intent: ExternalGatewayOutboundIntent,
  targetMessageId?: string
): ExternalGatewayOutboundOptions {
  return {
    idempotencyKey: intent.idempotencyKey ?? idempotencyKeyFromOutboundKey(intent.outboundKey),
    operationKey: intent.outboundKey,
    targetMessageId: targetMessageId ?? intent.providerMessageId ?? undefined,
    reconciliationHint: intent.providerMessageId ? { providerMessageId: intent.providerMessageId } : undefined
  }
}

export function idempotencyKeyFromOutboundKey(outboundKey: string): string {
  const hash = genericHash(outboundKey).slice(0, 32)
  return `${hash.slice(0, 8)}-${hash.slice(8, 12)}-${hash.slice(12, 16)}-${hash.slice(16, 20)}-${hash.slice(20, 32)}`
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
  operation: Extract<ExternalGatewayOutboxOperation, 'post' | 'reply' | 'divider' | 'card'>
): unknown {
  /*
   * The gateway owns only a small operation switch. Provider-native rendering
   * remains adapter-owned; for card/divider this function prepares the minimal
   * postable object the adapter already declares it can handle.
   */
  if (operation === 'divider') return { ...payload, type: 'divider' }
  if (operation === 'card') return isExternalGatewayCardPayload(payload) ? payload : undefined

  if (typeof payload.text === 'string') return payload.text
  if (typeof payload.markdown === 'string' || typeof payload.raw === 'string' || 'ast' in payload) {
    return payload
  }

  return undefined
}

function postableFromEditPayload(payload: JsonObject): unknown {
  if (isExternalGatewayCardPayload(payload)) return payload
  if (typeof payload.text === 'string') return payload.text
  if (typeof payload.markdown === 'string' || typeof payload.raw === 'string' || 'ast' in payload) return payload

  return undefined
}

function fallbackTextFromFinalPayload(
  payload: JsonObject,
  operation: Extract<ExternalGatewayOutboxOperation, 'post' | 'reply' | 'divider' | 'card'>
): string {
  if (typeof payload.text === 'string') return payload.text
  if (typeof payload.markdown === 'string') return payload.markdown
  if (typeof payload.fallbackText === 'string') return payload.fallbackText
  if (typeof payload.raw === 'string') return payload.raw
  if (operation === 'divider') return '[divider]'
  if (isExternalGatewayCardPayload(payload)) return cardPayloadFallbackText(payload)

  return JSON.stringify(payload)
}

function emojiFromFinalPayload(payload: JsonObject): unknown {
  // Canonical reaction key is `emoji`; `rawEmoji` is the platform-native fallback.
  return payload.emoji ?? payload.rawEmoji ?? undefined
}

function targetMessageIdFromFinalPayload(payload: JsonObject): string | undefined {
  // Producers set `targetMessageId` for delete-by-id; `targetOutboundKey` is
  // resolved separately. No producer sets the other historical aliases.
  const value = payload.targetMessageId
  return typeof value === 'string' && value.length > 0 ? value : undefined
}

function roomFromIntent(
  intent: ExternalGatewayOutboundIntent,
  room: Record<string, unknown>,
  adapter: ExternalGatewayAdapter
): Required<Pick<ExternalGatewayRoomInput, 'id'>> & ExternalGatewayRoomInput {
  return {
    id: intent.providerRoomId,
    isDM: typeof room.isDM === 'boolean' ? room.isDM : (adapter.isDM?.(intent.providerThreadId) ?? false),
    metadata:
      typeof room.metadata === 'object' && room.metadata !== null && !Array.isArray(room.metadata)
        ? (room.metadata as JsonObject)
        : {},
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
