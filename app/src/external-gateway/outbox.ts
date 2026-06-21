import { genericHash } from '@agentbull/bullx-native-addons'
import { match, ms } from '@pleisto/active-support'
import { and, asc, eq, sql } from 'drizzle-orm'
import { DB, jsonbParam } from '@/common/database'
import { ExternalGatewayOutbox, type JsonObject } from '@/common/db-schema'
import { logger } from '@/common/logger'
import { redactSensitiveText } from '@/security/redact'
import type { AgentResult } from '@/principals/agents/service'
import { adapterSupportsCapability, requireOutboundCapability } from './core/capabilities'
import { UnsupportedChannelCapabilityError } from './core/errors'
import { parseMarkdown } from './core/markdown'
import { bullxCardPayloadFallbackText, isBullXExternalGatewayCardPayload } from '@agentbull/bullx-sdk/plugins'
import type { ExternalGatewayProjectionSink } from './core/projection'
import type { ExternalGatewayAdapter, ExternalGatewayOutboundOptions, ExternalGatewayRoomInput } from './core/events'
import type { FileUpload } from './core/types'

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
   *                  optional files use JSON-safe descriptors:
   *                  `{ files: [{ filename, dataBase64 }] }` or `{ files: [{ filename, text }] }`
   * - card         : `{ kind: 'interactive_output', output }` or `{ kind: 'lark_native_card', card, fallbackText }`
   * - divider      : `{ kind: 'control_notice', text, fallbackText? }`
   * - edit         : `{ targetOutboundKey, text|interactive_output|lark_native_card, ... }` (or `intent.providerMessageId`);
   *                  `editFallback: "post"` opts command/progress edits into post fallback on permanent edit failures
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

// How long after a send started we still trust an idempotency key to suppress a
// duplicate. Tuned just under the providers' own dedup horizon (≈1h): past this
// window a retried send could create a second visible message, so a row stuck
// "send started" beyond it is failed as unknown rather than retried blindly.
const IDEMPOTENT_SEND_REPLAY_WINDOW_MS = ms('55m')
// After this many failed attempts the row is dead-lettered instead of retried
// forever; a human (or a later recovery) decides what to do with it.
const MAX_OUTBOX_RETRY_COUNT = 5
// Per-attempt backoff, indexed by retry count (see outboxBackoffSecondsSql).
// 5s → 25s → 2m → 10m: fast first retries for transient blips, long tail so a
// sustained provider outage does not hammer the API.
const OUTBOX_BACKOFF_MS = [5_000, 25_000, 120_000, 600_000] as const
// Errors that will never succeed on retry: the recipient/chat is gone, the bot
// was removed, the payload is rejected. Matching on provider message text is
// inherently brittle, but providers do not give stable machine codes for all of
// these, so text classification is the pragmatic line between "retry" and "give
// up". A row matching these is failed immediately instead of consuming retries.
// TODO: provisional — prefer provider error codes over message regex wherever a
// stable code exists; this list has to be revisited whenever a provider reworks
// its error strings.
const PERMANENT_DELIVERY_ERROR_PATTERNS = [
  /no conversation reference found/i,
  /chat not found/i,
  /user not found/i,
  /bot.*not.*member/i,
  /bot was blocked by the user/i,
  /forbidden: bot was kicked/i,
  /chat_id is empty/i,
  /recipient is not a valid/i,
  /^Request failed with status code 400$/i,
  /outbound not configured for channel/i,
  /ambiguous .* recipient/i,
  /User .* not in room/i
] as const
// Edit failures that mean the target message can no longer be edited (too old,
// or gone). When the intent opted into post-fallback, these convert a failed
// edit into a fresh post so the user still sees the content. `230075` is Lark's
// "edit window exceeded" code.
const PERMANENT_EDIT_FALLBACK_ERROR_PATTERNS = [
  /230075/,
  /exceeded the time that can be edited/i,
  /message.*not found/i,
  /message.*deleted/i,
  /message.*recalled/i,
  /message.*withdrawn/i,
  /target.*not found/i
] as const
// Edit failures that are temporary. These must NOT trigger post-fallback: the
// edit will likely work on the next retry, and posting a new message instead
// would leave a duplicate. Checked before the permanent list so an error that
// matches both (e.g. a 5xx) is treated as transient and retried.
const TRANSIENT_EDIT_FAILURE_PATTERNS = [
  /timeout/i,
  /timed out/i,
  /rate limit/i,
  /too many requests/i,
  /socket/i,
  /network/i,
  /econnreset/i,
  /temporarily unavailable/i,
  /request failed with status code 5\d\d/i
] as const

/**
 * Executes provider-visible side effects requested by the agent.
 *
 * Outbox rows are the owner of provider delivery status. A failed provider call
 * is recorded here and returned to the runtime; it must not cause the inbound
 * event that produced the intent to be marked failed after the agent accepted it.
 */
export class DrizzleExternalGatewayOutbox {
  /**
   * Persists an intent as a `pending` row without attempting delivery.
   *
   * This is the durable half of the transactional outbox: the agent records
   * what it wants sent, commits, and a later drain delivers it. Persisting first
   * is what lets delivery survive a crash between "agent decided" and "provider
   * called".
   */
  async enqueuePending(input: {
    agentUid: string
    bindingName: string
    intent: ExternalGatewayOutboundIntent
  }): Promise<typeof ExternalGatewayOutbox.$inferSelect> {
    return this.upsertPending(input.agentUid, input.bindingName, input.intent)
  }

  /** Persists several intents as pending rows. Order of `intents` is the send order a drain follows. */
  async enqueuePendingMany(input: {
    agentUid: string
    bindingName: string
    intents: readonly ExternalGatewayOutboundIntent[]
  }): Promise<void> {
    for (const intent of input.intents) await this.enqueuePending({ ...input, intent })
  }

  /**
   * Persists the intent and delivers it in one call.
   *
   * Returns early when the row is already in a terminal state (`sent` /
   * `unsupported` / `failed`): the upsert is idempotent on the outbound key, so
   * a redelivered intent that already settled is not sent a second time.
   */
  async dispatch(input: DispatchExternalGatewayOutboundInput): Promise<typeof ExternalGatewayOutbox.$inferSelect> {
    const row = await this.upsertPending(input.agent.agent.uid, input.bindingName, input.intent)
    if (row.status === 'sent' || row.status === 'unsupported' || row.status === 'failed') return row

    return this.dispatchRow(row, input)
  }

  /**
   * Delivers the binding's due `pending` rows, oldest first.
   *
   * Ordering by `createdAt` gives per-binding FIFO delivery so the user sees
   * messages in the order the agent produced them. Only rows past their backoff
   * window are selected (the SQL interval guard), and the batch is capped at 50
   * so one drain pass cannot monopolize the loop. Retry-exhausted rows are
   * dead-lettered up front so they leave the pending set before selection.
   *
   * Concurrency safety against two overlapping drains double-delivering the same
   * rows is the caller's job (the runtime's per-binding drain mutex); this
   * method does not lock.
   */
  async dispatchPendingForBinding(input: Omit<DispatchExternalGatewayOutboundInput, 'intent'>): Promise<void> {
    await this.deadLetterRetryExhausted(input.agent.agent.uid, input.bindingName)

    const rows = await DB.select()
      .from(ExternalGatewayOutbox)
      .where(
        and(
          eq(ExternalGatewayOutbox.agentUid, input.agent.agent.uid),
          eq(ExternalGatewayOutbox.bindingName, input.bindingName),
          eq(ExternalGatewayOutbox.status, 'pending'),
          sql`${ExternalGatewayOutbox.retryCount} < ${MAX_OUTBOX_RETRY_COUNT}`,
          sql`(${ExternalGatewayOutbox.lastAttemptAt} is null or ${ExternalGatewayOutbox.lastAttemptAt} < now() - (${outboxBackoffSecondsSql(
            ExternalGatewayOutbox.retryCount
          )} * interval '1 second'))`
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

  /**
   * Moves rows that spent their retry budget to `failed` and logs each one.
   *
   * `lastError` is preserved with `coalesce` so the real provider error that
   * caused the final failure is kept; only rows that somehow have no recorded
   * error fall back to the generic `retry_exhausted` marker.
   */
  private async deadLetterRetryExhausted(agentUid: string, bindingName: string): Promise<void> {
    const rows = await DB.update(ExternalGatewayOutbox)
      .set({
        status: 'failed',
        recoveryState: 'not_started',
        safeError: 'retry_exhausted',
        lastError: sql`coalesce(${ExternalGatewayOutbox.lastError}, 'retry_exhausted')`,
        updatedAt: sql`now()`
      })
      .where(
        and(
          eq(ExternalGatewayOutbox.agentUid, agentUid),
          eq(ExternalGatewayOutbox.bindingName, bindingName),
          eq(ExternalGatewayOutbox.status, 'pending'),
          sql`${ExternalGatewayOutbox.retryCount} >= ${MAX_OUTBOX_RETRY_COUNT}`
        )
      )
      .returning({
        outboundKey: ExternalGatewayOutbox.outboundKey,
        retryCount: ExternalGatewayOutbox.retryCount
      })

    for (const row of rows) {
      logger.error(
        { agentUid, bindingName, outboundKey: row.outboundKey, retryCount: row.retryCount },
        'External Gateway outbox dead-lettered after retry budget'
      )
    }
  }

  /**
   * Delivers one row, first deciding whether a prior interrupted attempt is safe
   * to repeat.
   *
   * The hard case is crash recovery: a row marked `send_attempt_started` means a
   * previous process called the provider but never recorded the outcome — the
   * send may or may not have landed. The guards below decide between reconcile,
   * replay, and give-up so the system never double-posts:
   *  - if a provider message id was captured, try to reconcile against it;
   *  - else, if the adapter cannot prove idempotency, refuse to replay (a blind
   *    retry could duplicate) and mark the outcome unknown;
   *  - else, if the idempotency window has expired, also refuse — the key is no
   *    longer trusted to dedupe.
   * Only after passing these does it (re)mark the attempt started and dispatch by
   * operation.
   */
  private async dispatchRow(
    row: typeof ExternalGatewayOutbox.$inferSelect,
    input: DispatchExternalGatewayOutboundInput
  ): Promise<typeof ExternalGatewayOutbox.$inferSelect> {
    const key = outboxKeyFromRow(row)

    // We have an id for the in-flight message: ask the provider whether it
    // actually exists before resending, turning a maybe-duplicate into a
    // confirmed send when it does.
    if (row.recoveryState === 'send_attempt_started' && row.providerMessageId) {
      const reconciled = await this.tryReconcileExisting(row, input)
      if (reconciled) return reconciled
    }

    // No id captured, but the key may have aged out of the provider's dedup
    // horizon. Replaying now risks a second visible message, so stop and mark it
    // unknown for an operator instead of guessing.
    if (
      row.recoveryState === 'send_attempt_started' &&
      !row.providerMessageId &&
      adapterSupportsCapability(input.adapter, 'outbound', 'outbound_idempotency') &&
      row.platformSendStartedAt &&
      Date.now() - row.platformSendStartedAt.getTime() > IDEMPOTENT_SEND_REPLAY_WINDOW_MS
    ) {
      return this.markUnknownAfterSend(key, 'Previous send attempt is outside the idempotency replay window')
    }

    // Adapter has no idempotency guarantee at all: any replay of an
    // already-started send could duplicate, so we never retry it blindly.
    if (
      row.recoveryState === 'send_attempt_started' &&
      !adapterSupportsCapability(input.adapter, 'outbound', 'outbound_idempotency')
    ) {
      return this.markUnknownAfterSend(key, 'Previous send attempt started and adapter cannot prove idempotency')
    }

    // Records "about to call the provider" before the call, so a crash mid-send
    // leaves the row in the recoverable `send_attempt_started` state handled above.
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

  /**
   * Delivers post / reply / divider / card — every operation that produces a new
   * provider message through `postMessage`.
   *
   * On success it both marks the row sent and projects the message into the
   * mirror, so the agent's own outbound shows up in chat history exactly like an
   * inbound one. A missing capability is terminal (`unsupported`); any other
   * error goes to `markProviderFailure`, which decides retry vs permanent.
   */
  private async dispatchPostLike(
    key: ExternalGatewayOutboxKey,
    input: DispatchExternalGatewayOutboundInput,
    operation: Extract<ExternalGatewayOutboxOperation, 'post' | 'reply' | 'divider' | 'card'>
  ): Promise<typeof ExternalGatewayOutbox.$inferSelect> {
    const postable = postableFromFinalPayload(input.intent.finalPayload, operation)
    if (postable === undefined) return this.markUnsupported(key, `Final ${operation} payload is not postable`)
    const text = fallbackTextFromFinalPayload(input.intent.finalPayload, operation)

    try {
      // post/reply are distinct provider capabilities even though both go through
      // `postMessage`; divider/card keep their own capability name unchanged.
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

  /**
   * Inserts the pending row, or returns the existing one for this outbound key.
   *
   * `(agentUid, bindingName, outboundKey)` is the idempotency anchor: the same
   * logical send always maps to one row. `onConflictDoNothing` plus a re-select
   * means a redelivered intent returns the already-stored row (with whatever
   * status it has reached) instead of creating a duplicate or resetting it.
   */
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

  /**
   * Marks the row delivered and records the provider message id.
   *
   * Clears recovery state and any stored error so a row that succeeded on a
   * retry does not keep a stale failure around. Also doubles as the success path
   * for reconciliation, where the id came from the provider rather than a fresh
   * send.
   */
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

  /** Terminal: the operation cannot be performed on this channel at all. Never retried. */
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

  /**
   * Classifies a provider call failure into one of three outcomes.
   *
   * The error message is redacted first because it is stored and may contain
   * recipient identifiers or tokens. Then:
   *  - a permanent delivery error fails the row immediately (no retry);
   *  - otherwise, if the adapter can prove idempotency, the row goes back to
   *    `pending` with an incremented retry count for backoff-gated retry — safe
   *    because a duplicate from the earlier attempt would be deduped;
   *  - otherwise the outcome is genuinely unknown (the send may have landed but
   *    we cannot retry safely), so it is parked as unknown-after-send.
   */
  private async markProviderFailure(
    key: ExternalGatewayOutboxKey,
    adapter: ExternalGatewayAdapter,
    error: unknown
  ): Promise<typeof ExternalGatewayOutbox.$inferSelect> {
    const reason = redactSensitiveText(error instanceof Error ? error.message : String(error))
    if (isPermanentDeliveryError(reason)) {
      const [row] = await DB.update(ExternalGatewayOutbox)
        .set({
          status: 'failed',
          recoveryState: 'not_started',
          lastAttemptAt: new Date(),
          lastError: reason,
          safeError: reason,
          updatedAt: sql`now()`
        })
        .where(outboxKeyWhere(key))
        .returning()
      if (!row) throw new ExternalGatewayOutboxError(`Failed to mark outbox ${key.outboundKey} failed`)
      return row
    }
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

  /**
   * Terminal-but-ambiguous: a send was started and we cannot prove whether it
   * reached the user. Fails the row but tags `recoveryState` as
   * `unknown_after_send` so it is distinguishable from a clean failure — the one
   * case where at-least-once could have produced a visible message we did not
   * record. Left for operator/monitoring follow-up rather than auto-retried.
   */
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

  /**
   * Write-ahead checkpoint taken just before calling the provider.
   *
   * Stamping `send_attempt_started` (and the wall-clock start) before the call
   * is what makes a crash mid-send recoverable: on restart `dispatchRow` sees
   * this state and decides reconcile/replay/give-up. `platformSendStartedAt`
   * feeds the idempotency replay window.
   */
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

  /**
   * Deletes a target message, then projects the delete into the mirror.
   *
   * The target can be given directly (`targetMessageId`) or indirectly via the
   * outbound key of an earlier send (`targetOutboundKey`), which lets a producer
   * say "delete the thing I posted earlier" without knowing the provider id it
   * received. A target that resolves to nothing is `unsupported`, not retried.
   */
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

  /**
   * Edits a target message in place.
   *
   * Used heavily for streaming/progress messages that update as the agent works.
   * The target is resolved from the payload, the intent's provider id, or an
   * earlier send's outbound key. When the intent opts in (`editFallback: post`)
   * and the edit fails for a permanent reason — the message is too old to edit
   * or no longer exists — the content is posted as a fresh message instead, so
   * the user still receives it. Transient failures deliberately do not fall
   * back; they retry the edit to avoid leaving a duplicate.
   */
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
      if (editFallbackMode(input.intent.finalPayload) === 'post') {
        const shouldFallback =
          error instanceof UnsupportedChannelCapabilityError || isPermanentEditFailureForFallback(error)
        if (shouldFallback) return this.dispatchEditFallbackPost(key, input, postable, targetMessageId, error)
      }
      if (error instanceof UnsupportedChannelCapabilityError) return this.markUnsupported(key, error.message)
      return this.markProviderFailure(key, input.adapter, error)
    }
  }

  /**
   * Posts the edit's content as a new message after a permanent edit failure.
   *
   * Reached only from `dispatchEdit` once the failure is classified permanent
   * and the intent allows fallback. The original edit error is logged (redacted)
   * so the conversion is traceable, then this behaves like a normal post.
   */
  private async dispatchEditFallbackPost(
    key: ExternalGatewayOutboxKey,
    input: DispatchExternalGatewayOutboundInput,
    postable: unknown,
    targetMessageId: string,
    editError: unknown
  ): Promise<typeof ExternalGatewayOutbox.$inferSelect> {
    try {
      const postMessage = requireOutboundCapability(
        input.adapter,
        'post_message',
        input.adapter.postMessage?.bind(input.adapter)
      )
      const rawMessage = await postMessage(input.intent.providerThreadId, postable, outboundOptions(input.intent))
      logger.warn(
        {
          agentUid: key.agentUid,
          bindingName: key.bindingName,
          outboundKey: key.outboundKey,
          targetMessageId,
          reason: redactSensitiveText(errorText(editError))
        },
        'External Gateway edit failed permanently; posted fallback message'
      )
      const sent = await this.markSent(key, rawMessage.id)
      await projectVisibleOutbound({
        agent: input.agent,
        adapter: input.adapter,
        messageId: rawMessage.id,
        projection: input.projection,
        room: roomFromIntent(input.intent, input.room, input.adapter),
        raw: rawMessage.raw,
        text: fallbackTextFromFinalPayload(input.intent.finalPayload, 'post'),
        threadId: rawMessage.threadId || input.intent.providerThreadId
      })
      return sent
    } catch (fallbackError) {
      if (fallbackError instanceof UnsupportedChannelCapabilityError) {
        return this.markUnsupported(key, fallbackError.message)
      }
      return this.markProviderFailure(key, input.adapter, fallbackError)
    }
  }

  /**
   * Looks up the provider message id that an earlier outbox row (named by
   * `targetOutboundKey`) ended up with. This is how edit/delete target a message
   * by the logical key the producer used, without the producer having to track
   * the provider-assigned id itself.
   */
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

  /**
   * Adds or removes the bot's own reaction on a target message, then projects it.
   *
   * The reaction is attributed to a synthetic `self` user (isMe/isBot) so the
   * mirror's reaction map shows the bot among the reactors, matching how an
   * inbound reaction from a human would be recorded.
   */
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

  /**
   * After a crash, asks the provider whether the in-flight message actually
   * landed, and marks the row sent when it confirms a live message.
   *
   * Best-effort by design: if the adapter cannot reconcile, or the lookup
   * throws, this returns undefined and the caller falls through to the normal
   * replay/give-up path. A message that exists but was already deleted is not
   * treated as sent — re-sending is the right move there.
   */
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

/**
 * Builds the per-call options handed to an adapter, carrying the idempotency
 * key, the operation key, the resolved target id, and (when known) a
 * reconciliation hint so the adapter can dedupe and, after a crash, find the
 * message it may have already created.
 */
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

/**
 * Derives a deterministic idempotency key from an outbound key.
 *
 * The same outbound key always yields the same key, which is what makes a
 * retried send dedupe at the provider. The hash is sliced into UUID-shaped
 * 8-4-4-4-12 groups because some providers require the idempotency token to look
 * like a UUID; the dashes are cosmetic formatting, not extra entropy.
 */
export function idempotencyKeyFromOutboundKey(outboundKey: string): string {
  const hash = genericHash(outboundKey).slice(0, 32)
  return `${hash.slice(0, 8)}-${hash.slice(8, 12)}-${hash.slice(12, 16)}-${hash.slice(16, 20)}-${hash.slice(20, 32)}`
}

/**
 * Mirrors a just-sent outbound message into the projection as the bot's own
 * message.
 *
 * Keeps chat history complete: without this, the agent's replies would be
 * missing from the same mirror that long-term memory and recall read. The
 * author is the synthetic `self` user and the text is re-parsed to the shared
 * markdown AST so a bot message is shaped exactly like an inbound one.
 */
export async function projectVisibleOutbound(input: {
  adapter: { userName?: string }
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

/**
 * Turns a stored payload into the value the adapter's `postMessage` expects, or
 * `undefined` when the payload carries nothing sendable (which the caller maps
 * to `unsupported`).
 *
 * The shape returned is deliberately loose — a bare string for plain text, the
 * payload object for markdown/AST/card, or a `{ markdown, files }` object when
 * attachments are present — because each adapter knows how to consume these and
 * the gateway does not render.
 */
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
  if (operation === 'card') return isBullXExternalGatewayCardPayload(payload) ? payload : undefined

  const files = fileUploadsFromFinalPayload(payload)
  if (files.length > 0) {
    if (typeof payload.markdown === 'string' || typeof payload.raw === 'string' || 'ast' in payload) {
      return { ...payload, files }
    }
    return { markdown: typeof payload.text === 'string' ? payload.text : '', files }
  }

  if (typeof payload.text === 'string') return payload.text
  if (typeof payload.markdown === 'string' || typeof payload.raw === 'string' || 'ast' in payload) return payload

  return undefined
}

// Edit's counterpart to postableFromFinalPayload. Edits never carry file
// uploads, so the file branch is intentionally absent.
function postableFromEditPayload(payload: JsonObject): unknown {
  if (isBullXExternalGatewayCardPayload(payload)) return payload
  if (typeof payload.text === 'string') return payload.text
  if (typeof payload.markdown === 'string' || typeof payload.raw === 'string' || 'ast' in payload) return payload

  return undefined
}

function editFallbackMode(payload: JsonObject): 'post' | undefined {
  return payload.editFallback === 'post' ? 'post' : undefined
}

/**
 * Decides whether an edit error is permanent enough to justify post-fallback.
 *
 * Transient patterns are checked first and win: an error that looks both
 * transient and permanent (a flaky 5xx that also mentions "not found") is
 * treated as transient and retried, never converted to a duplicate post.
 */
function isPermanentEditFailureForFallback(error: unknown): boolean {
  const text = errorText(error)
  if (TRANSIENT_EDIT_FAILURE_PATTERNS.some(pattern => pattern.test(text))) return false
  return PERMANENT_EDIT_FALLBACK_ERROR_PATTERNS.some(pattern => pattern.test(text))
}

/**
 * Flattens an arbitrary thrown value into one searchable string for the
 * permanent/transient classifiers.
 *
 * Provider SDKs bury the meaningful code/message inside nested `response.data`
 * or a `cause` chain, and an Error's own fields are non-enumerable, so a plain
 * `String(error)` or `JSON.stringify` would drop exactly the text the patterns
 * match on. This pulls the known fields out explicitly and joins them, falling
 * back to JSON/string only when nothing structured was found.
 */
function errorText(error: unknown): string {
  if (typeof error === 'string') return error
  const parts: string[] = []
  if (error instanceof Error && error.message) parts.push(error.message)
  collectProviderErrorDetails(error, parts)
  if (parts.length > 0) return parts.join(' ')
  try {
    return JSON.stringify(error)
  } catch {
    return String(error)
  }
}

// Walks the error itself, its HTTP `response`/`response.data`, and its `cause`
// chain, collecting provider error fields from each level. The `cause !== error`
// guard stops a self-referential cause from looping forever.
function collectProviderErrorDetails(error: unknown, parts: string[]): void {
  if (!error || typeof error !== 'object') return
  const record = error as Record<string, unknown>
  appendProviderErrorFields(record, parts)
  const response = record.response
  if (response && typeof response === 'object') {
    const responseRecord = response as Record<string, unknown>
    appendProviderErrorFields(responseRecord, parts)
    appendProviderErrorFields(responseRecord.data, parts)
  }
  const cause = record.cause
  if (cause && cause !== error) collectProviderErrorDetails(cause, parts)
}

// Appends the provider error fields the classifiers key on (numeric/string
// codes, status, messages, Lark's `log_id`) as `key=value` tokens.
function appendProviderErrorFields(value: unknown, parts: string[]): void {
  if (!value || typeof value !== 'object') return
  const record = value as Record<string, unknown>
  for (const key of ['code', 'status', 'statusCode', 'statusText', 'msg', 'message', 'log_id']) {
    const field = record[key]
    if (typeof field === 'string' || typeof field === 'number') parts.push(`${key}=${field}`)
  }
}

/**
 * Derives a plain-text representation of any payload.
 *
 * Used both as the text projected into chat history and as the notification/
 * fallback text for surfaces that cannot render a card or files. Falls back
 * through text → markdown → explicit fallbackText → raw, then to synthetic
 * labels for dividers/cards/files, and finally to the JSON itself so something
 * always shows rather than an empty message.
 */
function fallbackTextFromFinalPayload(
  payload: JsonObject,
  operation: Extract<ExternalGatewayOutboxOperation, 'post' | 'reply' | 'divider' | 'card'>
): string {
  if (typeof payload.text === 'string') return payload.text
  if (typeof payload.markdown === 'string') return payload.markdown
  if (typeof payload.fallbackText === 'string') return payload.fallbackText
  if (typeof payload.raw === 'string') return payload.raw
  if (operation === 'divider') return '[divider]'
  if (isBullXExternalGatewayCardPayload(payload)) return bullxCardPayloadFallbackText(payload)
  const fileNames = fileNamesFromFinalPayload(payload)
  if (fileNames.length > 0) return `[files: ${fileNames.join(', ')}]`

  return JSON.stringify(payload)
}

/**
 * Decodes the JSON-safe file descriptors stored on a payload back into binary
 * uploads.
 *
 * The outbox column is `jsonb`, so producers cannot store raw bytes; they store
 * either base64 (`dataBase64`) or inline `text`, and this turns those into
 * Buffers for the adapter. Descriptors without a usable filename or body are
 * dropped rather than failing the whole send.
 */
function fileUploadsFromFinalPayload(payload: JsonObject): FileUpload[] {
  const files = Array.isArray(payload.files) ? payload.files : []
  return files.flatMap(file => {
    if (!file || typeof file !== 'object' || Array.isArray(file)) return []
    const record = file as Record<string, unknown>
    const filename = typeof record.filename === 'string' ? record.filename.trim() : ''
    if (!filename) return []

    const mimeType = typeof record.mimeType === 'string' && record.mimeType.trim() ? record.mimeType.trim() : undefined
    if (typeof record.dataBase64 === 'string' && record.dataBase64.trim()) {
      return [{ filename, mimeType, data: Buffer.from(record.dataBase64, 'base64') }]
    }
    if (typeof record.text === 'string') {
      return [{ filename, mimeType: mimeType ?? 'text/plain; charset=utf-8', data: Buffer.from(record.text) }]
    }
    return []
  })
}

function fileNamesFromFinalPayload(payload: JsonObject): string[] {
  const files = Array.isArray(payload.files) ? payload.files : []
  return files.flatMap(file => {
    if (!file || typeof file !== 'object' || Array.isArray(file)) return []
    const filename = (file as Record<string, unknown>).filename
    return typeof filename === 'string' && filename.trim() ? [filename.trim()] : []
  })
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

/**
 * Reconstructs a typed room input for projecting outbound, from the intent's
 * room id plus whatever the loosely-typed `room` record carries. Where a field
 * is missing it asks the adapter (is-DM, visibility) so the projected bot
 * message lands in a room shaped the same as one built from an inbound event.
 */
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

function isPermanentDeliveryError(error: string): boolean {
  return PERMANENT_DELIVERY_ERROR_PATTERNS.some(pattern => pattern.test(error))
}

/**
 * The backoff schedule as a SQL CASE on `retryCount`.
 *
 * The "is this row due yet?" test runs inside the drain's WHERE clause (compare
 * `lastAttemptAt` to `now()` minus this many seconds), so the JS backoff table
 * has to be mirrored in SQL rather than evaluated in app code. `retryCount <= 1`
 * shares the first step so the very first retry waits the shortest delay.
 */
function outboxBackoffSecondsSql(retryCount: typeof ExternalGatewayOutbox.retryCount) {
  return sql`case
    when ${retryCount} <= 1 then ${Math.ceil(OUTBOX_BACKOFF_MS[0] / 1000)}
    when ${retryCount} = 2 then ${Math.ceil(OUTBOX_BACKOFF_MS[1] / 1000)}
    when ${retryCount} = 3 then ${Math.ceil(OUTBOX_BACKOFF_MS[2] / 1000)}
    else ${Math.ceil(OUTBOX_BACKOFF_MS[3] / 1000)}
  end`
}

export class ExternalGatewayOutboxError extends Error {
  constructor(message: string) {
    super(message)
    this.name = 'ExternalGatewayOutboxError'
  }
}
