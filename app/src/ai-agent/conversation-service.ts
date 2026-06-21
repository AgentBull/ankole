import { genUUIDv7 } from '@agentbull/bullx-native-addons'
import { and, asc, eq, isNull, sql } from 'drizzle-orm'
import type { AssistantMessage } from '@/llm'
import { DB, jsonbParam, type QueryExecutor } from '@/common/database'
import {
  AiAgentConversations,
  AiAgentLlmTurns,
  AiAgentMessages,
  type AiAgentConversationGeneration,
  type JsonObject,
  type JsonValue
} from '@/common/db-schema'
import type { AgentMessage, SessionTreeEntry } from './core'
import { numberFromPath, stringFromPath, toJsonObject, toJsonValue } from '@/common/json'

export type AiAgentMessageRole = 'user' | 'assistant' | 'tool' | 'im_ambient'
export type AiAgentMessageKind = 'normal' | 'summary' | 'introspection' | 'error'
export type AiAgentLlmTurnKind =
  | 'generation'
  | 'retry_generation'
  | 'scheduled_task'
  | 'checkback_generation'
  | 'compression'
  | 'ambient_recognizer'
  | 'overflow_retry'
export type AiAgentLlmTurnStatus = 'started' | 'succeeded' | 'failed' | 'cancelled'
export type AiAgentModelProfileName = 'primary' | 'light' | 'heavy'

const MAX_PENDING_FOLLOWUPS = 10_000

export interface AiAgentConversationRoute {
  agentUid: string
  bindingName: string
  providerRealmId?: string | null
  providerRoomId: string
}

export interface ProviderRefs {
  event_id?: string
  message_ids?: string[]
  room_id?: string
  thread_id?: string
}

export interface PendingFollowup {
  actor?: JsonObject
  agent_message?: JsonObject
  created_at: string
  event_id: string
  event_source: string
  provider_refs: JsonObject
  room?: JsonObject
  sent_at?: string
  text: string
}

export interface PendingSteering {
  command_event_id: string
  created_at: string
  text: string
}

export interface AppendAiAgentMessageInput {
  agentMessage?: AgentMessage | AssistantMessage | JsonObject | null
  content: JsonValue[]
  conversationId: string
  eventId?: string | null
  eventSource?: string | null
  kind?: AiAgentMessageKind
  metadata?: JsonObject
  role: AiAgentMessageRole
  status?: 'generating' | 'complete'
}

export interface StartLlmTurnInput {
  agentUid: string
  branchId?: string | null
  callIndex?: number | null
  parentBranchId?: string | null
  conversationId: string
  kind: AiAgentLlmTurnKind
  leaseId?: string | null
  model: string
  profile: AiAgentModelProfileName
  provider: string
  cacheRetention?: string
  inputMessageIds?: string[]
  inputSummaryMessageId?: string | null
  maxTokens?: number
  reasoning?: string
  requestContext?: JsonObject
  requestPatches?: JsonValue[]
  requestRefs?: JsonValue[]
  temperature?: number
  toolResults?: JsonValue[]
  triggerEventId?: string | null
  triggerMessageId?: string | null
}

/**
 * Owns the durable conversation state in Postgres: the conversation rows, their
 * message transcript, the per-conversation generation lease envelope, and the
 * `llm_turns` audit trail. Everything that must survive a process restart lives
 * here; the runtime holds only process-local scheduling on top.
 *
 * Two concerns recur across these methods and explain most of the SQL shape:
 *
 *  - **The generation lease is a JSON envelope on the conversation row, not a
 *    separate table.** A run's ownership, heartbeat, cancellation, and its queues
 *    of pending follow-ups/steering all live under `generation`. Lease
 *    transitions are therefore single-row UPDATEs whose WHERE clause encodes the
 *    guard ("only if the lease is free / still mine / not cancelled"), which is
 *    what makes acquire/clear/cancel safe under concurrent workers without a
 *    separate lock table.
 *  - **Queue mutations that must not lose a concurrent write take the row's
 *    `FOR UPDATE` lock.** Appending a pending follow-up or steering, and removing
 *    one, read the row `FOR UPDATE` inside a transaction so they serialize against
 *    the committing run's drain — the ordering that keeps mid-run input from being
 *    dropped or double-applied.
 *
 * "Active" conversation everywhere means `ended_at IS NULL`: at most one per
 * conversation key is live, and rollover ends the old one as it opens the new.
 */
export class AiAgentConversationService {
  /** Stable identity of a conversation derived from its route (agent + binding + realm + room). Two deliveries to the same room map to the same key, which is how `getOrCreateActiveConversation` finds the existing live conversation. */
  conversationKey(route: AiAgentConversationRoute): string {
    return [
      'ai_agent_conversation:v1',
      `agent:${route.agentUid}`,
      `binding:${route.bindingName}`,
      `realm:${route.providerRealmId ?? 'default'}`,
      `room:${route.providerRoomId}`
    ].join(':')
  }

  /**
   * Returns the live conversation for a route, creating one if none is active.
   * The read-then-insert is not itself atomic; concurrent first-deliveries to a
   * brand-new room are serialized upstream (the gateway processes a room's events
   * in order), so the second caller sees the row the first created.
   */
  async getOrCreateActiveConversation(
    route: AiAgentConversationRoute,
    db: QueryExecutor = DB
  ): Promise<typeof AiAgentConversations.$inferSelect> {
    const existing = await this.getActiveConversation(route, db)
    if (existing) return existing

    const conversationKey = this.conversationKey(route)
    const [created] = await db
      .insert(AiAgentConversations)
      .values({
        id: genUUIDv7(),
        agentUid: route.agentUid,
        conversationKey,
        generation: jsonbParam({}),
        metadata: jsonbParam({
          route: routeJson(route)
        })
      })
      .returning()
    if (!created) throw new AiAgentConversationError('Failed to create active conversation')
    return created
  }

  /** The single live conversation for a route, or undefined. "Live" is the `ended_at IS NULL` row; ended conversations (rolled over, reset) are excluded. */
  async getActiveConversation(
    route: AiAgentConversationRoute,
    db: QueryExecutor = DB
  ): Promise<typeof AiAgentConversations.$inferSelect | undefined> {
    const conversationKey = this.conversationKey(route)
    const [existing] = await db
      .select()
      .from(AiAgentConversations)
      .where(
        and(
          eq(AiAgentConversations.agentUid, route.agentUid),
          eq(AiAgentConversations.conversationKey, conversationKey),
          isNull(AiAgentConversations.endedAt)
        )
      )
      .limit(1)

    return existing
  }

  /**
   * Active, uncancelled-lease conversations for one binding — the crash-recovery
   * candidate set. Keeps the `generation->>'lease_id'` / `cancelled_at` JSON-path
   * predicate inside the generation-state home instead of the runtime.
   */
  async findRecoverableGenerations(
    agentUid: string,
    bindingName: string
  ): Promise<Array<typeof AiAgentConversations.$inferSelect>> {
    return DB.select()
      .from(AiAgentConversations)
      .where(
        and(
          eq(AiAgentConversations.agentUid, agentUid),
          isNull(AiAgentConversations.endedAt),
          sql`${AiAgentConversations.metadata}->'route'->>'binding_name' = ${bindingName}`,
          sql`coalesce(${AiAgentConversations.generation}->>'lease_id', '') <> ''`,
          sql`coalesce(${AiAgentConversations.generation}->>'cancelled_at', '') = ''`
        )
      )
  }

  /**
   * Ends the active conversation (if any) and opens a fresh one for the same
   * route — the `/new` and daily-reset transition. The new row links back to its
   * predecessor via `previous_conversation_id`, so the session history forms a
   * chain rather than vanishing.
   *
   * Runs in one transaction guarded by a `pg_advisory_xact_lock` on the
   * conversation key: two concurrent rollovers of the same room cannot both end
   * the old and create two new conversations — the second blocks until the first
   * commits, then sees the result. The lock is keyed on the conversation, not the
   * whole table, so unrelated rooms roll over in parallel.
   *
   * `sourceEventId` makes rollover idempotent for command-driven resets: if the
   * already-active conversation was opened by this same event, it is returned
   * as-is instead of rolling over again (a redelivered `/new` must not start a
   * third conversation).
   */
  async rolloverConversation(
    route: AiAgentConversationRoute,
    reason: 'new_session' | 'daily_reset',
    db: QueryExecutor = DB,
    options: { sourceEventId?: string } = {}
  ): Promise<typeof AiAgentConversations.$inferSelect> {
    // Re-enter inside a transaction so the advisory lock and both writes share one
    // unit of work; the recursive call carries the tx as `db`.
    if (db === DB) {
      return DB.transaction(tx => this.rolloverConversation(route, reason, tx, options))
    }

    const conversationKey = this.conversationKey(route)
    // Transaction-scoped advisory lock: serializes rollovers of this one
    // conversation key and auto-releases at commit/rollback.
    await (db as QueryExecutor & { execute(query: unknown): Promise<unknown> }).execute(
      sql`select pg_advisory_xact_lock(hashtext(${conversationKey}))`
    )

    const existing = await this.getActiveConversation(route, db)
    // Idempotency: the live conversation already belongs to this triggering event,
    // so this is a redelivery — return it untouched.
    if (existing && rolloverSourceEventId(existing.metadata) === options.sourceEventId && options.sourceEventId) {
      return existing
    }

    if (existing) {
      await db
        .update(AiAgentConversations)
        .set({
          endedAt: new Date(),
          generation: jsonbParam(cancelGeneration(existing.generation, reason, undefined)),
          metadata: sql`jsonb_set(${AiAgentConversations.metadata}, '{end_reason}', ${JSON.stringify(reason)}::jsonb, true)`,
          updatedAt: sql`now()`
        })
        .where(eq(AiAgentConversations.id, existing.id))
    }

    const [created] = await db
      .insert(AiAgentConversations)
      .values({
        id: genUUIDv7(),
        agentUid: route.agentUid,
        conversationKey,
        generation: jsonbParam({}),
        metadata: jsonbParam({
          route: routeJson(route),
          ...(existing ? { previous_conversation_id: existing.id } : {}),
          rollover_reason: reason,
          ...(options.sourceEventId ? { rollover_source_event_id: options.sourceEventId } : {})
        })
      })
      .returning()
    if (!created) throw new AiAgentConversationError('Failed to rollover conversation')
    return created
  }

  /**
   * Appends a transcript row, idempotent on `(event_source, event_id)`. A given
   * inbound event must produce exactly one message even if delivered twice (the
   * gateway retries, recovery replays), so the insert is `onConflictDoNothing`
   * and, when it no-ops, the existing row is read back and returned. Rows without
   * an event id (internally-minted notes) cannot dedupe this way and are expected
   * to be unique by construction; a conflict there is a real error.
   */
  async appendMessage(
    input: AppendAiAgentMessageInput,
    db: QueryExecutor = DB
  ): Promise<typeof AiAgentMessages.$inferSelect> {
    const [conversation] = await db
      .select({ agentUid: AiAgentConversations.agentUid })
      .from(AiAgentConversations)
      .where(eq(AiAgentConversations.id, input.conversationId))
      .limit(1)
    if (!conversation) throw new AiAgentConversationError(`Unknown conversation ${input.conversationId}`)

    const [inserted] = await db
      .insert(AiAgentMessages)
      .values({
        id: genUUIDv7(),
        agentUid: conversation.agentUid,
        conversationId: input.conversationId,
        role: input.role,
        kind: input.kind ?? 'normal',
        status: input.status ?? 'complete',
        content: jsonbParam(input.content),
        agentMessage: input.agentMessage ? jsonbParam(toJsonObject(input.agentMessage)) : null,
        eventSource: input.eventSource ?? null,
        eventId: input.eventId ?? null,
        metadata: jsonbParam(input.metadata ?? {})
      })
      .onConflictDoNothing()
      .returning()
    if (inserted) return inserted

    // Insert no-opped on the idempotency conflict: a row for this event already
    // exists, so load and return it. Without an event id there is nothing to
    // re-read by, so a conflict here is unexpected and surfaces as an error.
    if (!input.eventSource || !input.eventId) throw new AiAgentConversationError('Failed to append message')
    const [existing] = await db
      .select()
      .from(AiAgentMessages)
      .where(
        and(
          eq(AiAgentMessages.conversationId, input.conversationId),
          eq(AiAgentMessages.eventSource, input.eventSource),
          eq(AiAgentMessages.eventId, input.eventId)
        )
      )
      .limit(1)
    if (!existing) throw new AiAgentConversationError('Failed to load idempotent message')
    return existing
  }

  /**
   * The live transcript as the model should currently see it: chronological,
   * tombstoned rows excluded, and collapsed at the most recent compaction.
   *
   * Compaction handling is the subtle part. When a complete `summary` row exists,
   * the returned view is that summary followed by everything from its
   * `first_kept_message_id` onward — the pre-summary history is represented by the
   * summary alone, not re-sent. A summary that did not record a first-kept id
   * falls back to slicing from the summary itself (keep summary + all rows after
   * it); a recorded id that no longer resolves (its row was tombstoned since)
   * degrades the same way. `(created_at, id)` ordering keeps the sequence stable
   * when two rows share a timestamp.
   */
  async renderedMessages(
    conversationId: string,
    db: QueryExecutor = DB
  ): Promise<Array<typeof AiAgentMessages.$inferSelect>> {
    const rows = await db
      .select()
      .from(AiAgentMessages)
      .where(
        and(
          eq(AiAgentMessages.conversationId, conversationId),
          // Skip rows retracted by a recall/delete (see lifecycle-revisions).
          sql`${AiAgentMessages.metadata}->'transcript_effect' is null`
        )
      )
      .orderBy(asc(AiAgentMessages.createdAt), asc(AiAgentMessages.id))

    // No completed summary => the full (untombstoned) history is the view.
    const latestSummaryIndex = rows.findLastIndex(row => row.kind === 'summary' && row.status === 'complete')
    if (latestSummaryIndex < 0) return rows

    const summary = rows[latestSummaryIndex]!
    const firstKept = stringFromPath(summary.metadata, ['compression', 'first_kept_message_id'])
    if (!firstKept) return rows.slice(latestSummaryIndex)
    const firstKeptIndex = rows.findIndex(row => row.id === firstKept)
    // Summary, then the kept tail. If the kept anchor is gone, keep everything
    // after the summary instead of dropping rows.
    return [summary, ...rows.slice(firstKeptIndex < 0 ? latestSummaryIndex + 1 : firstKeptIndex)]
  }

  /** The rendered transcript projected into the upstream `SessionTreeEntry[]` shape that the compaction engine consumes, so compaction operates on exactly the rows the live context shows. */
  async sessionEntries(conversationId: string, db: QueryExecutor = DB): Promise<SessionTreeEntry[]> {
    const rows = await this.renderedMessages(conversationId, db)
    // Project Postgres rows into upstream pi `SessionTreeEntry[]` using the shared inclusion classifier, so
    // compaction sees exactly the rows the live context does. The rendered rows already form a linear path,
    // so `parentId` chains to the previous emitted entry; `timestamp` uses the upstream ISO format.
    let parentId: string | null = null
    return rows.flatMap<SessionTreeEntry>(row => {
      const projection = classifyRenderedRow(row)
      if (projection === 'skip') return []
      const id = row.id
      const timestamp = row.createdAt.toISOString()
      const entryParentId = parentId
      parentId = id
      if (projection === 'summary') {
        return [
          {
            type: 'compaction' as const,
            id,
            parentId: entryParentId,
            timestamp,
            summary: textFromContent(row.content),
            firstKeptEntryId: stringFromPath(row.metadata, ['compression', 'first_kept_message_id']) ?? id,
            tokensBefore: numberFromPath(row.metadata, ['compression', 'tokens_before']) ?? 0,
            details: row.metadata.compression
          }
        ]
      }
      return [
        {
          type: 'message' as const,
          id,
          parentId: entryParentId,
          timestamp,
          message: row.agentMessage as unknown as AgentMessage
        }
      ]
    })
  }

  /**
   * Tries to take the generation lease for a conversation, atomically. The single
   * conditional UPDATE is the mutual-exclusion primitive: it writes a new lease
   * only when none is held OR the held one is already cancelled, so exactly one of
   * several racing workers wins and the rest get `undefined` and back off. A
   * cancelled lease is reusable here on purpose — that is how a `/stop`ped or
   * recalled run's conversation can be picked up again by the next trigger.
   */
  async acquireGenerationLease(input: {
    conversationId: string
    eventId?: string | null
    triggerMessageId: string
  }): Promise<{ leaseId: string } | undefined> {
    const leaseId = genUUIDv7()
    const [row] = await DB.update(AiAgentConversations)
      .set({
        generation: jsonbParam(newGenerationLease(leaseId, input.triggerMessageId, input.eventId)),
        updatedAt: sql`now()`
      })
      .where(
        and(
          eq(AiAgentConversations.id, input.conversationId),
          // Win only if the lease slot is empty or its current holder was cancelled.
          sql`(coalesce(${AiAgentConversations.generation}->>'lease_id', '') = '' or coalesce(${AiAgentConversations.generation}->>'cancelled_at', '') <> '')`
        )
      )
      .returning()
    return row ? { leaseId } : undefined
  }

  /**
   * Releases the lease at the clean end of a run, but only if it is still ours and
   * uncancelled — the WHERE fences out the case where a newer lease replaced ours
   * or a cancel landed mid-run, so a finishing zombie cannot wipe a successor's
   * lease. Returns whether it actually cleared. Cancelled leases are intentionally
   * left in place for `acquireGenerationLease` to recycle.
   */
  async clearGenerationLease(conversationId: string, leaseId: string): Promise<boolean> {
    const [row] = await DB.update(AiAgentConversations)
      .set({ generation: jsonbParam({}), updatedAt: sql`now()` })
      .where(
        and(
          eq(AiAgentConversations.id, conversationId),
          isNull(AiAgentConversations.endedAt),
          sql`${AiAgentConversations.generation}->>'lease_id' = ${leaseId}`,
          sql`coalesce(${AiAgentConversations.generation}->>'cancelled_at', '') = ''`
        )
      )
      .returning()
    return Boolean(row)
  }

  /**
   * Read-only fence check used right before committing a run's output: true only
   * when this exact lease still owns a live, uncancelled conversation. A false
   * here means the run was taken over or stopped while it worked, and its result
   * must be discarded rather than written. This is the cheap pre-check; the commit
   * path still re-verifies under its own write so the decision cannot go stale.
   */
  async generationCanCommit(conversationId: string, leaseId: string): Promise<boolean> {
    const [row] = await DB.select({ id: AiAgentConversations.id })
      .from(AiAgentConversations)
      .where(
        and(
          eq(AiAgentConversations.id, conversationId),
          isNull(AiAgentConversations.endedAt),
          sql`${AiAgentConversations.generation}->>'lease_id' = ${leaseId}`,
          sql`coalesce(${AiAgentConversations.generation}->>'cancelled_at', '') = ''`
        )
      )
      .limit(1)
    return Boolean(row)
  }

  /**
   * Process-liveness heartbeat, driven by a wall-clock interval while a run is
   * in flight. Unlike {@link touchGenerationHeartbeat} it also pushes the
   * `max_expires_at` ceiling forward, because liveness makes no statement about
   * progress — a healthy long-thinking model may stream nothing for half an
   * hour. Lease expiry therefore means exactly one thing: the owning process
   * stopped beating (crashed, or lost the conversation). Runaway-run protection
   * lives in the stall watchdog and `maxTurns`, not here.
   */
  async touchGenerationLiveness(conversationId: string, leaseId: string): Promise<boolean> {
    const [row] = await DB.update(AiAgentConversations)
      .set({
        generation: sql`${AiAgentConversations.generation} || jsonb_build_object(
          'heartbeat_at', now()::text,
          'expires_at', (now() + interval '5 minutes')::text,
          'max_expires_at', GREATEST(
            coalesce((${AiAgentConversations.generation}->>'max_expires_at')::timestamptz, now()),
            now() + interval '5 minutes'
          )::text
        )`,
        updatedAt: sql`now()`
      })
      .where(
        and(
          eq(AiAgentConversations.id, conversationId),
          isNull(AiAgentConversations.endedAt),
          sql`${AiAgentConversations.generation}->>'lease_id' = ${leaseId}`,
          sql`coalesce(${AiAgentConversations.generation}->>'cancelled_at', '') = ''`
        )
      )
      .returning()
    return Boolean(row)
  }

  /**
   * Record the live streaming-card message of the current attempt on its lease.
   * The handle only lives in process memory; if the process dies mid-run, this
   * ref is what lets crash recovery and lease takeover delete the orphaned
   * "thinking" card instead of leaving it spinning in the chat forever.
   */
  async recordGenerationStreamingCard(
    conversationId: string,
    leaseId: string,
    card: { provider_message_id: string; provider_room_id?: string; provider_thread_id?: string }
  ): Promise<boolean> {
    const [row] = await DB.update(AiAgentConversations)
      .set({
        generation: sql`${AiAgentConversations.generation} || ${jsonbParam({ streaming_card: card })}`,
        updatedAt: sql`now()`
      })
      .where(
        and(
          eq(AiAgentConversations.id, conversationId),
          isNull(AiAgentConversations.endedAt),
          sql`${AiAgentConversations.generation}->>'lease_id' = ${leaseId}`
        )
      )
      .returning()
    return Boolean(row)
  }

  /**
   * Stamps the reasoning-trace reference (id + view url) onto the lease so a
   * recovering process can re-expose the same trace, and the committed assistant
   * message can link to it. Gated on lease ownership but — unlike the commit
   * fences — not on `cancelled_at`: this is descriptive metadata, harmless to
   * attach even to a lease that is being cancelled, and merging it in keeps any
   * concurrently-appended pending queue intact.
   */
  async recordGenerationReasoningTrace(
    conversationId: string,
    leaseId: string,
    trace: NonNullable<AiAgentConversationGeneration['reasoning_trace']>
  ): Promise<boolean> {
    const [row] = await DB.update(AiAgentConversations)
      .set({
        generation: sql`${AiAgentConversations.generation} || ${jsonbParam({ reasoning_trace: trace })}`,
        updatedAt: sql`now()`
      })
      .where(
        and(
          eq(AiAgentConversations.id, conversationId),
          isNull(AiAgentConversations.endedAt),
          sql`${AiAgentConversations.generation}->>'lease_id' = ${leaseId}`
        )
      )
      .returning()
    return Boolean(row)
  }

  /**
   * Cancel the active lease in place (single-statement jsonb merge, so concurrent
   * pending-queue appends are preserved). `expectedLeaseId` scopes the cancel to
   * one lease: a no-op if that lease was already replaced by a newer generation.
   */
  async cancelGeneration(
    conversationId: string,
    reason: string,
    eventId?: string | null,
    expectedLeaseId?: string
  ): Promise<void> {
    const conditions = [
      eq(AiAgentConversations.id, conversationId),
      sql`coalesce(${AiAgentConversations.generation}->>'lease_id', '') <> ''`
    ]
    if (expectedLeaseId) conditions.push(sql`${AiAgentConversations.generation}->>'lease_id' = ${expectedLeaseId}`)
    await DB.update(AiAgentConversations)
      .set({
        generation: sql`${AiAgentConversations.generation} || ${jsonbParam({
          cancelled_at: new Date().toISOString(),
          cancellation_reason: reason,
          cancelled_by_event_id: eventId ?? null
        })}`,
        updatedAt: sql`now()`
      })
      .where(and(...conditions))
  }

  /**
   * Next free `call_index` for a lease. Crash recovery reruns a lease whose
   * earlier calls already recorded turns; starting again at 0 would violate the
   * per-lease unique index and silently kill the recovered run.
   */
  async nextLlmTurnCallIndex(conversationId: string, leaseId: string): Promise<number> {
    const [row] = await DB.select({ max: sql<number | null>`max(${AiAgentLlmTurns.callIndex})` })
      .from(AiAgentLlmTurns)
      .where(and(eq(AiAgentLlmTurns.conversationId, conversationId), eq(AiAgentLlmTurns.leaseId, leaseId)))
    return (row?.max ?? -1) + 1
  }

  /**
   * Settle `started` turns abandoned by a dead or wedged run (process loss, or a
   * lease takeover) so the audit trail does not show phantom in-flight calls.
   * Turns the run already settled (succeeded/cancelled/failed) are untouched.
   */
  async failAbandonedLlmTurns(conversationId: string, leaseId: string, error: string): Promise<number> {
    const rows = await DB.update(AiAgentLlmTurns)
      .set({
        status: 'failed',
        completedAt: sql`now()`,
        response: sql`${AiAgentLlmTurns.response} || ${jsonbParam({ error_message: error })}`,
        updatedAt: sql`now()`
      })
      .where(
        and(
          eq(AiAgentLlmTurns.conversationId, conversationId),
          eq(AiAgentLlmTurns.leaseId, leaseId),
          eq(AiAgentLlmTurns.status, 'started')
        )
      )
      .returning({ id: AiAgentLlmTurns.id })
    return rows.length
  }

  /**
   * Queue an inbound message behind the active run so the committing generation
   * drains it. Returns `false` when there is no live, uncancelled lease to attach
   * to — i.e. the run committed or was cancelled between the caller's (non-locking)
   * snapshot and this call. The single `FOR UPDATE` read serializes this against
   * {@link AiAgentRuntime.commitAssistantResult}, so the outcome is deterministic:
   * either the append lands on a lease the committer still sees and drains, or it
   * reports the lease as gone. A `false` return MUST make the caller fall through
   * and turn the message into its own trigger; appending to a dead `generation`
   * envelope would orphan it (no recovery path drains a lease-less queue, and the
   * next `acquireGenerationLease` overwrites it). Duplicate deliveries and a
   * saturated queue still return `true` (already accounted for on the live lease)
   * so the caller does not create a second message row that would collide with the
   * committer's drain insert of the same event.
   */
  async appendPendingFollowup(conversationId: string, followup: PendingFollowup): Promise<boolean> {
    return DB.transaction(async tx => {
      const [conversation] = await tx
        .select({ endedAt: AiAgentConversations.endedAt, generation: AiAgentConversations.generation })
        .from(AiAgentConversations)
        .where(eq(AiAgentConversations.id, conversationId))
        .for('update')
        .limit(1)
      if (!conversation || conversation.endedAt || !isActiveGeneration(conversation.generation)) return false
      const pending = (Array.isArray(conversation.generation.pending_followups)
        ? conversation.generation.pending_followups
        : []) as unknown as PendingFollowup[]
      const isDuplicate = pending.some(item => item?.event_id === followup.event_id)
      if (isDuplicate || pending.length >= MAX_PENDING_FOLLOWUPS) return true
      await tx
        .update(AiAgentConversations)
        .set({
          generation: sql`jsonb_set(${AiAgentConversations.generation}, '{pending_followups}', coalesce(${AiAgentConversations.generation}->'pending_followups', '[]'::jsonb) || ${jsonbParam([toJsonValue(followup)])}, true)`,
          updatedAt: sql`now()`
        })
        .where(eq(AiAgentConversations.id, conversationId))
      return true
    })
  }

  /**
   * Queue a `/steer` instruction behind the active run. Same lease-fenced contract
   * as {@link appendPendingFollowup}: `false` means no live lease to attach to, so
   * the caller must materialize the steer and start a fresh generation instead of
   * orphaning it.
   */
  async appendPendingSteering(conversationId: string, steering: PendingSteering): Promise<boolean> {
    return DB.transaction(async tx => {
      const [conversation] = await tx
        .select({ endedAt: AiAgentConversations.endedAt, generation: AiAgentConversations.generation })
        .from(AiAgentConversations)
        .where(eq(AiAgentConversations.id, conversationId))
        .for('update')
        .limit(1)
      if (!conversation || conversation.endedAt || !isActiveGeneration(conversation.generation)) return false
      const pending = (Array.isArray(conversation.generation.pending_steering)
        ? conversation.generation.pending_steering
        : []) as unknown as PendingSteering[]
      const isDuplicate = pending.some(item => item?.command_event_id === steering.command_event_id)
      if (isDuplicate) return true
      await tx
        .update(AiAgentConversations)
        .set({
          generation: sql`jsonb_set(${AiAgentConversations.generation}, '{pending_steering}', coalesce(${AiAgentConversations.generation}->'pending_steering', '[]'::jsonb) || ${jsonbParam([toJsonValue(steering)])}, true)`,
          updatedAt: sql`now()`
        })
        .where(eq(AiAgentConversations.id, conversationId))
      return true
    })
  }

  /** Drops a still-queued follow-up whose source provider message was recalled, before it ever becomes transcript. Returns whether one was removed. Matches on the follow-up's recorded `provider_refs.message_ids`. */
  async removePendingFollowupByProviderMessageId(conversationId: string, providerMessageId: string): Promise<boolean> {
    return this.removePendingArrayItem<PendingFollowup>(conversationId, 'pending_followups', followup => {
      const refs = followup.provider_refs
      const messageIds = Array.isArray(refs.message_ids) ? refs.message_ids : []
      return messageIds.some(messageId => messageId === providerMessageId)
    })
  }

  /** Opens an `llm_turns` audit row in `started` state just before a provider call, capturing the request snapshot, model/profile, and lease/branch/call-index links. Settled later by {@link finishLlmTurn}. */
  async startLlmTurn(input: StartLlmTurnInput): Promise<typeof AiAgentLlmTurns.$inferSelect> {
    const [row] = await DB.insert(AiAgentLlmTurns)
      .values({
        id: genUUIDv7(),
        agentUid: input.agentUid,
        conversationId: input.conversationId,
        kind: input.kind,
        status: 'started',
        profile: input.profile,
        provider: input.provider,
        model: input.model,
        reasoning: input.reasoning ?? null,
        temperature: input.temperature === undefined ? null : String(input.temperature),
        maxTokens: input.maxTokens ?? null,
        cacheRetention: input.cacheRetention ?? null,
        leaseId: input.leaseId ?? null,
        callIndex: input.callIndex ?? null,
        branchId: input.branchId ?? null,
        parentBranchId: input.parentBranchId ?? null,
        triggerMessageId: input.triggerMessageId ?? null,
        triggerEventId: input.triggerEventId ?? null,
        inputMessageIds: jsonbParam(input.inputMessageIds ?? []),
        inputSummaryMessageId: input.inputSummaryMessageId ?? null,
        requestContext: jsonbParam(input.requestContext ?? {}),
        requestRefs: jsonbParam(input.requestRefs ?? []),
        requestPatches: jsonbParam(input.requestPatches ?? []),
        response: jsonbParam({}),
        toolResults: jsonbParam(input.toolResults ?? []),
        usage: jsonbParam({}),
        providerMetadata: jsonbParam({})
      })
      .returning()
    if (!row) throw new AiAgentConversationError('Failed to start LLM turn')
    return row
  }

  /** Closes an `llm_turns` row with its terminal status and the observed result (assistant response, token usage, provider metadata, tool results). */
  async finishLlmTurn(input: {
    llmTurnId: string
    providerMetadata?: JsonObject
    response?: JsonObject
    status: AiAgentLlmTurnStatus
    toolResults?: JsonValue[]
    usage?: JsonObject
  }): Promise<void> {
    await DB.update(AiAgentLlmTurns)
      .set({
        status: input.status,
        response: jsonbParam(input.response ?? {}),
        toolResults: jsonbParam(input.toolResults ?? []),
        usage: jsonbParam(input.usage ?? {}),
        providerMetadata: jsonbParam(input.providerMetadata ?? {}),
        completedAt: new Date(),
        updatedAt: sql`now()`
      })
      .where(eq(AiAgentLlmTurns.id, input.llmTurnId))
  }

  /**
   * Read-modify-write removal of one entry from a pending queue, under the row's
   * `FOR UPDATE` lock so it serializes against the run's drain and against a
   * concurrent append — the whole array is rewritten, so without the lock a racing
   * write would be clobbered. Returns whether anything was removed; an unchanged
   * length short-circuits the write.
   */
  private async removePendingArrayItem<T>(
    conversationId: string,
    key: 'pending_followups' | 'pending_steering',
    predicate: (item: T) => boolean
  ): Promise<boolean> {
    return DB.transaction(async tx => {
      const [conversation] = await tx
        .select()
        .from(AiAgentConversations)
        .where(eq(AiAgentConversations.id, conversationId))
        .for('update')
        .limit(1)
      if (!conversation) return false

      const values = Array.isArray(conversation.generation[key]) ? (conversation.generation[key] as T[]) : []
      const kept = values.filter(item => !predicate(item))
      // Nothing matched the predicate: skip the write entirely.
      if (kept.length === values.length) return false

      await tx
        .update(AiAgentConversations)
        .set({
          generation: sql`jsonb_set(${AiAgentConversations.generation}, ${sql.raw(`'{${key}}'`)}, ${jsonbParam(toJsonValue(kept))}, true)`,
          updatedAt: sql`now()`
        })
        .where(eq(AiAgentConversations.id, conversationId))
      return true
    })
  }
}

/** Process-wide singleton; the runtime and its collaborators share this one conversation store. */
export const aiAgentConversationService = new AiAgentConversationService()

/** Build the `provider_refs` metadata sub-object as a durable {@link JsonObject} (see {@link ProviderRefs} for the shape). */
export function providerRefs(input: {
  eventId?: string | null
  providerMessageId?: string | null
  providerRoomId: string
  providerThreadId: string
}): JsonObject {
  return {
    event_id: input.eventId ?? null,
    message_ids: input.providerMessageId ? [input.providerMessageId] : [],
    room_id: input.providerRoomId,
    thread_id: input.providerThreadId
  }
}

export function textContent(text: string): JsonValue[] {
  return [{ type: 'text', text }]
}

/** Flattens a content-block array to its plain text, concatenating every block's `text` and ignoring non-text blocks. */
export function textFromContent(content: JsonValue[]): string {
  return content
    .flatMap(block =>
      typeof block === 'object' && block !== null && !Array.isArray(block) && typeof block.text === 'string'
        ? [block.text]
        : []
    )
    .join('')
}

/**
 * Single builder for the `metadata.route` envelope shared by conversation rows
 * (room-scoped) and message rows (thread-scoped). Both `provider_room_id` and
 * `provider_thread_id` are always present (null when not applicable) so the shape
 * cannot diverge between its two producers (conversation service + runtime).
 */
export function buildRouteMetadata(input: {
  agentUid: string
  bindingName: string
  providerRealmId?: string | null
  providerRoomId?: string | null
  providerThreadId?: string | null
}): JsonObject {
  return {
    agent_uid: input.agentUid,
    binding_name: input.bindingName,
    provider_realm_id: input.providerRealmId ?? null,
    provider_room_id: input.providerRoomId ?? null,
    provider_thread_id: input.providerThreadId ?? null
  }
}

// Conversation-scoped route envelope (no thread): the room-level `metadata.route`
// stored on a conversation row.
function routeJson(route: AiAgentConversationRoute): JsonObject {
  return buildRouteMetadata({
    agentUid: route.agentUid,
    bindingName: route.bindingName,
    providerRealmId: route.providerRealmId,
    providerRoomId: route.providerRoomId
  })
}

// The event id that opened a conversation via rollover, if any — the idempotency
// key {@link AiAgentConversationService.rolloverConversation} checks to avoid
// rolling over twice for one command.
function rolloverSourceEventId(metadata: JsonObject): string | undefined {
  const value = metadata.rollover_source_event_id
  return typeof value === 'string' && value.length > 0 ? value : undefined
}

// In-memory cancel transform applied to the *old* conversation's generation as it
// is ended during rollover (the method `cancelGeneration` is the DB-side version).
// A generation with no lease is returned unchanged — there is nothing to cancel.
function cancelGeneration(
  generation: AiAgentConversationGeneration,
  reason: string,
  eventId?: string | null
): AiAgentConversationGeneration {
  if (!generation.lease_id) return generation
  return {
    ...generation,
    cancelled_at: new Date().toISOString(),
    cancellation_reason: reason,
    cancelled_by_event_id: eventId ?? null
  }
}

/** True when the generation holds an active (uncancelled) lease. */
export function isActiveGeneration(generation: { lease_id?: unknown; cancelled_at?: unknown }): boolean {
  return typeof generation.lease_id === 'string' && generation.lease_id.length > 0 && !generation.cancelled_at
}

/**
 * True when an active lease has outlived `expires_at`, i.e. the run stopped
 * heartbeating (wedged provider stream, wedged tool, or a crashed process whose
 * recovery also died). Healthy runs keep `expires_at` ahead of now via
 * `touchGenerationHeartbeat`. Accepts both ISO (lease creation) and PostgreSQL
 * text (heartbeat refresh) timestamp formats; an unparseable or missing
 * `expires_at` counts as not expired so a malformed lease is never force-taken.
 */
export function isExpiredGeneration(
  generation: { lease_id?: unknown; cancelled_at?: unknown; expires_at?: unknown },
  at: Date = new Date()
): boolean {
  if (!isActiveGeneration(generation)) return false
  if (typeof generation.expires_at !== 'string') return false
  const expiresAt = Date.parse(generation.expires_at)
  return Number.isFinite(expiresAt) && expiresAt < at.getTime()
}

/**
 * Build a fresh generation lease payload. Single source of truth shared by the conversation service and the
 * runtime, so the lease shape (timeouts, empty pending queues) cannot drift between call sites.
 */
export function newGenerationLease(
  leaseId: string,
  triggerMessageId: string,
  triggerEventId?: string | null
): JsonObject {
  const now = new Date()
  return {
    lease_id: leaseId,
    trigger_message_id: triggerMessageId,
    trigger_event_id: triggerEventId ?? null,
    started_at: now.toISOString(),
    heartbeat_at: now.toISOString(),
    expires_at: new Date(now.getTime() + 5 * 60 * 1000).toISOString(),
    max_expires_at: new Date(now.getTime() + 30 * 60 * 1000).toISOString(),
    cancelled_at: null,
    cancellation_reason: null,
    cancelled_by_event_id: null,
    pending_followups: [],
    pending_steering: []
  }
}

/**
 * Single source of truth for which rendered rows enter the model's view and compaction, and as what.
 * `render` (live context) and `sessionEntries` (compaction input) both consume this so their inclusion
 * rules cannot drift: ambient scene facts and failed/aborted assistants are dropped from both; every row
 * carrying an `agentMessage` (including introspection notes) is a message; summaries are summaries.
 */
export function classifyRenderedRow(row: typeof AiAgentMessages.$inferSelect): 'summary' | 'message' | 'skip' {
  if (row.kind === 'summary') return 'summary'
  if (row.role === 'im_ambient' && row.kind === 'normal') return 'skip'
  if (row.role === 'assistant' && row.kind === 'error') return 'skip'
  if (!row.agentMessage) return 'skip'
  return 'message'
}

export class AiAgentConversationError extends Error {
  constructor(message: string) {
    super(message)
    this.name = 'AiAgentConversationError'
  }
}
