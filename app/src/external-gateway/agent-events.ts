import { ms } from '@pleisto/active-support'
import { and, asc, eq, gte, inArray, lte, or, sql } from 'drizzle-orm'
import { DB, jsonbParam, type QueryExecutor } from '@/common/database'
import {
  ExternalGatewayAgentEvents,
  ExternalGatewayInputTombstones,
  type JsonObject,
  type JsonValue
} from '@/common/db-schema'
import { redactSensitiveText } from '@/security/redact'

export type ExternalGatewayCanonicalType =
  | 'message.received'
  | 'message.deleted'
  | 'message.recalled'
  | 'reaction.added'
  | 'reaction.removed'
  | 'action'
  | 'slash_command'

export type ExternalGatewayDeliveryMode = 'addressed' | 'ambient' | 'command' | 'action' | 'lifecycle'

export type ExternalGatewayAgentEventStatus = 'pending' | 'done' | 'failed'

export type ExternalGatewaySlashCommandName = 'new' | 'compress' | 'retry' | 'steer' | 'stop'

export interface ExternalGatewaySlashCommandStub {
  argsText: string
  name: ExternalGatewaySlashCommandName
  raw: string
  status: 'stub'
}

/**
 * Payload carried inside the envelope's `data`. This is the snapshot the
 * executor reads: the normalized message/room/mentions, the original provider
 * `raw` for adapters that need it, and the per-room session the turn belongs to.
 */
export interface ExternalGatewayAgentEnvelopeData {
  command?: ExternalGatewaySlashCommandStub
  mentions?: JsonValue[]
  message?: JsonObject
  raw?: JsonValue | null
  room: JsonObject
  session: {
    id: string
    scope: 'external_room'
  }
}

/**
 * The CloudEvents-1.0-shaped envelope persisted as the input row's payload and
 * delivered to the executor. The gateway speaks this one canonical event shape
 * regardless of which IM platform produced it.
 */
export interface ExternalGatewayAgentEnvelope {
  data: ExternalGatewayAgentEnvelopeData
  id: string
  source: string
  specversion: '1.0'
  subject: string
  time: string
  type: ExternalGatewayCanonicalType
}

export interface EnqueueExternalGatewayAgentEventInput {
  agentUid: string
  actorKey?: string | null
  batchKey?: string | null
  bindingName: string
  deliveryMode: ExternalGatewayDeliveryMode
  payload: ExternalGatewayAgentEnvelope
  providerEventId: string
  providerMessageId?: string | null
  providerRoomId: string
  providerThreadId: string
  quietUntil?: Date
  type: ExternalGatewayCanonicalType
}

export type EnqueueExternalGatewayInboundMessageInput = Omit<
  EnqueueExternalGatewayAgentEventInput,
  'providerMessageId' | 'quietUntil'
> & {
  providerMessageId: string
  quietUntil?: Date
  type: Extract<ExternalGatewayCanonicalType, 'message.received' | 'slash_command'>
}

export interface ExternalGatewayAgentDelivery {
  events: Array<typeof ExternalGatewayAgentEvents.$inferSelect>
}

/**
 * Minimal identity of one input row: (agent, binding, providerEventId). Used to
 * exclude rows already claimed by an in-flight delivery and to address a row for
 * markDone/markFailed.
 */
export type ExternalGatewayAgentEventKey = Pick<
  typeof ExternalGatewayAgentEvents.$inferSelect,
  'agentUid' | 'bindingName' | 'providerEventId'
>

/**
 * An in-flight event key plus the room/message/type fields the claim predicates
 * need to also hold back lifecycle (delete/recall) events for a receive that is
 * still being delivered.
 */
export type ExternalGatewayInFlightAgentEvent = ExternalGatewayAgentEventKey &
  Pick<typeof ExternalGatewayAgentEvents.$inferSelect, 'providerMessageId' | 'providerRoomId' | 'type'>

/**
 * How long an addressed receive waits before it becomes claimable, so a fast
 * burst of replies in the same room/thread coalesces into one agent turn. Kept
 * small (75ms) because it is pure added latency on the common single-message
 * case; it only needs to span the gap between back-to-back webhook deliveries.
 */
export const NORMAL_RECEIVE_BATCH_WINDOW_MS = 75
/**
 * Lifetime of the stale-receive tombstone. Long enough (24h) to cover a provider
 * that delivers a recall well before its out-of-order original receive, but
 * bounded so the guard table self-expires instead of growing forever.
 */
const INPUT_TOMBSTONE_TTL_MS = ms('24h')
/** Hard cap so one runaway room cannot pull an unbounded batch into a turn. */
const MAX_ADDRESSED_RECEIVE_BATCH_SIZE = 10_000

export class DrizzleExternalGatewayAgentEventQueue {
  /**
   * Accepts one normalized agent-facing event into the unlogged input window.
   *
   * `providerEventId` is the idempotency key for provider redelivery. It is not
   * an audit id; duplicate delivery returns the existing runtime row.
   */
  async enqueue(input: EnqueueExternalGatewayAgentEventInput): Promise<typeof ExternalGatewayAgentEvents.$inferSelect> {
    return DB.transaction(async tx => {
      return enqueueInTransaction(tx, input)
    })
  }

  /**
   * Enqueues a received message or slash command, unless a delete/recall for it
   * already arrived.
   *
   * Takes the per-message advisory lock first, then re-checks the tombstone
   * inside it, so a recall that is racing this enqueue cannot slip in between
   * the check and the insert. Returns undefined when the tombstone wins (the
   * message was recalled before we could deliver it).
   */
  async enqueueInboundMessage(
    input: EnqueueExternalGatewayInboundMessageInput
  ): Promise<typeof ExternalGatewayAgentEvents.$inferSelect | undefined> {
    return DB.transaction(async tx => {
      await lockInputTombstoneKey(tx, input)
      if (await hasLiveInputTombstone(tx, input)) return undefined
      return enqueueInTransaction(tx, input)
    })
  }

  /**
   * Enqueues an addressed receive into the batch window.
   *
   * Thin wrapper over {@link enqueueInboundMessage} that sets `type` and the
   * `quietUntil` so the row stays unclaimable for the batch window and a burst
   * of replies coalesces into one turn.
   */
  async enqueueReceive(
    input: Omit<EnqueueExternalGatewayInboundMessageInput, 'quietUntil' | 'type'>
  ): Promise<typeof ExternalGatewayAgentEvents.$inferSelect | undefined> {
    return this.enqueueInboundMessage({
      ...input,
      quietUntil: new Date(Date.now() + NORMAL_RECEIVE_BATCH_WINDOW_MS),
      type: 'message.received'
    })
  }

  /**
   * Mutates an addressed receive that is still inside the quiet batch window.
   *
   * Delete/recall uses `remove` and hard-deletes the pending row. Marking it
   * `done` would falsely imply that the agent saw the message, causing a later
   * duplicate lifecycle event to be delivered to the agent.
   */
  async mutatePendingReceive(input: {
    agentUid: string
    bindingName: string
    inFlightEvents?: readonly ExternalGatewayAgentEventKey[]
    providerMessageId: string
    providerRoomId: string
    payload?: ExternalGatewayAgentEnvelope
    remove?: boolean
  }): Promise<'mutated' | 'removed' | 'in_flight' | 'not_pending'> {
    return DB.transaction(async tx => {
      const [event] = await tx
        .select()
        .from(ExternalGatewayAgentEvents)
        .where(
          and(
            eq(ExternalGatewayAgentEvents.agentUid, input.agentUid),
            eq(ExternalGatewayAgentEvents.bindingName, input.bindingName),
            eq(ExternalGatewayAgentEvents.providerRoomId, input.providerRoomId),
            eq(ExternalGatewayAgentEvents.providerMessageId, input.providerMessageId),
            eq(ExternalGatewayAgentEvents.type, 'message.received'),
            eq(ExternalGatewayAgentEvents.status, 'pending')
          )
        )
        .for('update')
        .limit(1)

      if (!event) return 'not_pending'

      if (input.remove) {
        if (isInFlightEvent(event, input.inFlightEvents)) return 'in_flight'
        await tx.delete(ExternalGatewayAgentEvents).where(agentEventKeyWhere(event))
        return 'removed'
      }

      if (input.payload) {
        await tx
          .update(ExternalGatewayAgentEvents)
          .set({
            payload: jsonbParam(input.payload as unknown as JsonObject),
            updatedAt: sql`now()`
          })
          .where(agentEventKeyWhere(event))
      }

      return 'mutated'
    })
  }

  /**
   * Checks whether a same-room delete/recall arrived before this receive.
   *
   * Provider message ids are not assumed globally unique across rooms. The room
   * scope is part of the input-window identity even though the projection has
   * its own `(room_id, message_id)` uniqueness.
   */
  async hasInputTombstone(input: {
    agentUid: string
    bindingName: string
    providerMessageId: string
    providerRoomId: string
  }): Promise<boolean> {
    return hasLiveInputTombstone(DB, input)
  }

  /**
   * Records a short-lived stale-receive guard for delete/recall-before-receive.
   */
  async recordInputTombstone(input: {
    agentUid: string
    bindingName: string
    providerMessageId: string
    providerRoomId: string
  }): Promise<void> {
    await DB.transaction(async tx => {
      await lockInputTombstoneKey(tx, input)
      const expiresAt = new Date(Date.now() + INPUT_TOMBSTONE_TTL_MS)
      await tx
        .insert(ExternalGatewayInputTombstones)
        .values({
          agentUid: input.agentUid,
          bindingName: input.bindingName,
          providerRoomId: input.providerRoomId,
          providerMessageId: input.providerMessageId,
          expiresAt
        })
        .onConflictDoUpdate({
          target: [
            ExternalGatewayInputTombstones.agentUid,
            ExternalGatewayInputTombstones.bindingName,
            ExternalGatewayInputTombstones.providerRoomId,
            ExternalGatewayInputTombstones.providerMessageId
          ],
          set: {
            expiresAt,
            updatedAt: sql`now()`
          }
        })
    })
  }

  /**
   * Claims the next ready delivery for processing, oldest first.
   *
   * "Ready" means pending, past its `availableAt`, for an eligible agent, not
   * already in-flight, and (for lifecycle events) not blocked behind a receive
   * still being delivered. Ordering by `createdAt` then `providerEventId` gives
   * a stable FIFO with a deterministic tiebreak. When the head row is a
   * batchable addressed receive, the whole same-actor batch is claimed together.
   *
   * @returns the claimed events, or undefined when nothing is ready right now.
   */
  async claimReady(
    input: {
      agentUids?: readonly string[]
      /** Events already claimed by an in-flight delivery; rows stay pending until markDone/markFailed. */
      excludeEvents?: readonly ExternalGatewayAgentEventKey[]
      /** Lifecycle events for these receives must wait until the receive delivery settles. */
      blockLifecycleForReceives?: readonly ExternalGatewayInFlightAgentEvent[]
    } = {}
  ): Promise<ExternalGatewayAgentDelivery | undefined> {
    if (input.agentUids && input.agentUids.length === 0) return undefined

    return DB.transaction(async tx => {
      const readyPredicate = and(
        eq(ExternalGatewayAgentEvents.status, 'pending'),
        lte(ExternalGatewayAgentEvents.availableAt, new Date()),
        input.agentUids ? inArray(ExternalGatewayAgentEvents.agentUid, [...input.agentUids]) : undefined,
        notInEvents(input.excludeEvents),
        notLifecycleBlockedByInFlightReceives(input.blockLifecycleForReceives)
      )

      const [first] = await tx
        .select()
        .from(ExternalGatewayAgentEvents)
        .where(readyPredicate)
        .orderBy(asc(ExternalGatewayAgentEvents.createdAt), asc(ExternalGatewayAgentEvents.providerEventId))
        .for('update')
        .limit(1)

      if (!first) return undefined

      /*
       * This intentionally does not write a DB lease. PostgreSQL stores pending
       * accepted input, and this process owns short-lived in-flight work until
       * markDone/markFailed. If the process dies before completion, the row is
       * still pending.
       */
      const events = isReadyBatchableReceive(first) ? await claimReadyBatch(tx, first, input.excludeEvents) : [first]
      return { events }
    })
  }

  /**
   * Returns when the soonest not-yet-ready pending event becomes claimable,
   * under the same eligibility filters as {@link claimReady}.
   *
   * The drain loop uses this to arm its next wakeup precisely (e.g. at the end
   * of a batch window) instead of polling, so a row waiting on `availableAt` is
   * picked up the moment it ripens.
   */
  async nextPendingAvailableAt(
    input: {
      agentUids?: readonly string[]
      excludeEvents?: readonly ExternalGatewayAgentEventKey[]
      blockLifecycleForReceives?: readonly ExternalGatewayInFlightAgentEvent[]
    } = {}
  ): Promise<Date | undefined> {
    if (input.agentUids && input.agentUids.length === 0) return undefined

    const pendingPredicate = and(
      eq(ExternalGatewayAgentEvents.status, 'pending'),
      input.agentUids ? inArray(ExternalGatewayAgentEvents.agentUid, [...input.agentUids]) : undefined,
      notInEvents(input.excludeEvents),
      notLifecycleBlockedByInFlightReceives(input.blockLifecycleForReceives)
    )

    const [row] = await DB.select({ availableAt: ExternalGatewayAgentEvents.availableAt })
      .from(ExternalGatewayAgentEvents)
      .where(pendingPredicate)
      .orderBy(asc(ExternalGatewayAgentEvents.availableAt), asc(ExternalGatewayAgentEvents.createdAt))
      .limit(1)

    return row?.availableAt
  }

  /**
   * Marks agent-accepted input as terminal.
   *
   * Provider outbound failure after agent acceptance belongs to the outbox row,
   * not to this input-window status.
   */
  async markDone(events: readonly ExternalGatewayAgentEventKey[]): Promise<void> {
    if (events.length === 0) return

    await DB.update(ExternalGatewayAgentEvents)
      .set({ status: 'done', updatedAt: sql`now()` })
      .where(agentEventKeysWhere(events))
  }

  /**
   * Marks input that could not be handed to the agent executor.
   *
   * This is terminal runtime state, not a retry request. Retrying failed agent
   * delivery would require an explicit agent/runtime recovery design.
   */
  async markFailed(events: readonly ExternalGatewayAgentEventKey[], error: unknown): Promise<void> {
    if (events.length === 0) return

    const reason = redactSensitiveText(error instanceof Error ? error.message : String(error))
    await DB.update(ExternalGatewayAgentEvents)
      .set({
        status: 'failed',
        payload: sql`jsonb_set(${ExternalGatewayAgentEvents.payload}, '{safe_error}', ${JSON.stringify(reason)}::jsonb, true)`,
        updatedAt: sql`now()`
      })
      .where(agentEventKeysWhere(events))
  }
}

export const externalGatewayAgentEventQueue = new DrizzleExternalGatewayAgentEventQueue()

function isBatchableReceive(input: EnqueueExternalGatewayAgentEventInput): boolean {
  return (
    input.type === 'message.received' &&
    input.deliveryMode === 'addressed' &&
    input.batchKey !== undefined &&
    input.batchKey !== null
  )
}

function isReadyBatchableReceive(event: typeof ExternalGatewayAgentEvents.$inferSelect): boolean {
  return event.type === 'message.received' && event.deliveryMode === 'addressed' && event.batchKey !== null
}

/**
 * Idempotent insert of one input row, keyed by provider event id.
 *
 * `onConflictDoNothing` then re-select means provider redelivery returns the
 * existing row instead of erroring or duplicating. A successful insert of a
 * batchable receive also slides the batch window forward so later messages in
 * the burst join the same turn. The throw is a real invariant violation: a
 * conflict with no findable existing row should be impossible.
 */
async function enqueueInTransaction(
  tx: QueryExecutor,
  input: EnqueueExternalGatewayAgentEventInput
): Promise<typeof ExternalGatewayAgentEvents.$inferSelect> {
  const availableAt = input.quietUntil ?? new Date()
  const [event] = await tx
    .insert(ExternalGatewayAgentEvents)
    .values({
      agentUid: input.agentUid,
      bindingName: input.bindingName,
      providerRoomId: input.providerRoomId,
      providerThreadId: input.providerThreadId,
      providerEventId: input.providerEventId,
      providerMessageId: input.providerMessageId ?? null,
      type: input.type,
      deliveryMode: input.deliveryMode,
      batchKey: input.batchKey ?? null,
      actorKey: input.actorKey ?? null,
      payload: jsonbParam(input.payload as unknown as JsonObject),
      status: 'pending',
      availableAt
    })
    .onConflictDoNothing()
    .returning()

  if (event) {
    if (isBatchableReceive(input)) {
      await extendPendingBatchWindow(tx, input.agentUid, input.bindingName, input.batchKey!, availableAt)
    }
    return event
  }

  const [existing] = await tx
    .select()
    .from(ExternalGatewayAgentEvents)
    .where(
      and(
        eq(ExternalGatewayAgentEvents.agentUid, input.agentUid),
        eq(ExternalGatewayAgentEvents.bindingName, input.bindingName),
        eq(ExternalGatewayAgentEvents.providerEventId, input.providerEventId)
      )
    )
    .limit(1)

  if (!existing) throw new ExternalGatewayAgentEventQueueError(`Failed to enqueue ${input.providerEventId}`)
  return existing
}

/**
 * Serializes enqueue and tombstone-record for one provider message.
 *
 * A transaction-scoped advisory lock on the message key is what closes the
 * recall-versus-receive race: whichever side takes it first runs to commit
 * before the other observes state, so a recall cannot land between a receive's
 * tombstone check and its insert (and vice versa).
 */
async function lockInputTombstoneKey(
  tx: QueryExecutor,
  input: {
    agentUid: string
    bindingName: string
    providerMessageId: string
    providerRoomId: string
  }
): Promise<void> {
  await tx.execute(sql`select pg_advisory_xact_lock(hashtext(${externalGatewayInputTombstoneLockKey(input)}))`)
}

/**
 * The string hashed into the advisory lock id for a message. Exported so tests
 * can take the same lock and drive the race deterministically.
 */
export function externalGatewayInputTombstoneLockKey(input: {
  agentUid: string
  bindingName: string
  providerMessageId: string
  providerRoomId: string
}): string {
  return JSON.stringify([input.agentUid, input.bindingName, input.providerRoomId, input.providerMessageId])
}

async function hasLiveInputTombstone(
  db: QueryExecutor,
  input: {
    agentUid: string
    bindingName: string
    providerMessageId: string
    providerRoomId: string
  }
): Promise<boolean> {
  const rows = await db
    .select({ providerMessageId: ExternalGatewayInputTombstones.providerMessageId })
    .from(ExternalGatewayInputTombstones)
    .where(
      and(
        eq(ExternalGatewayInputTombstones.agentUid, input.agentUid),
        eq(ExternalGatewayInputTombstones.bindingName, input.bindingName),
        eq(ExternalGatewayInputTombstones.providerRoomId, input.providerRoomId),
        eq(ExternalGatewayInputTombstones.providerMessageId, input.providerMessageId),
        gte(ExternalGatewayInputTombstones.expiresAt, new Date())
      )
    )
    .limit(1)

  return rows.length > 0
}

/**
 * Pushes every pending row in a batch to the same new `availableAt`.
 *
 * Keeps the whole burst ready at once (rather than each message ripening on its
 * own clock) so they are claimed together as one turn. Touches only still-pending
 * rows; anything already claimed or done is left alone.
 */
async function extendPendingBatchWindow(
  db: QueryExecutor,
  agentUid: string,
  bindingName: string,
  batchKey: string,
  availableAt: Date
): Promise<void> {
  await db
    .update(ExternalGatewayAgentEvents)
    .set({
      availableAt,
      updatedAt: sql`now()`
    })
    .where(
      and(
        eq(ExternalGatewayAgentEvents.agentUid, agentUid),
        eq(ExternalGatewayAgentEvents.bindingName, bindingName),
        eq(ExternalGatewayAgentEvents.batchKey, batchKey),
        eq(ExternalGatewayAgentEvents.type, 'message.received'),
        eq(ExternalGatewayAgentEvents.deliveryMode, 'addressed'),
        eq(ExternalGatewayAgentEvents.status, 'pending')
      )
    )
}

/**
 * Collects the contiguous run of same-actor receives that share the head row's
 * batch key, in FIFO order, to deliver as one turn.
 *
 * The loop stops at the first row from a different actor (the head row itself is
 * always kept): a turn is one user's burst, so it must not absorb a second
 * speaker's message that happened to arrive into the same room window. Falls
 * back to just the head row if the run is empty.
 */
async function claimReadyBatch(
  db: QueryExecutor,
  first: typeof ExternalGatewayAgentEvents.$inferSelect,
  excludeEvents?: readonly ExternalGatewayAgentEventKey[]
): Promise<Array<typeof ExternalGatewayAgentEvents.$inferSelect>> {
  if (!first.batchKey) return [first]

  const rows = await db
    .select()
    .from(ExternalGatewayAgentEvents)
    .where(
      and(
        eq(ExternalGatewayAgentEvents.agentUid, first.agentUid),
        eq(ExternalGatewayAgentEvents.bindingName, first.bindingName),
        eq(ExternalGatewayAgentEvents.batchKey, first.batchKey),
        eq(ExternalGatewayAgentEvents.type, 'message.received'),
        eq(ExternalGatewayAgentEvents.deliveryMode, 'addressed'),
        eq(ExternalGatewayAgentEvents.status, 'pending'),
        lte(ExternalGatewayAgentEvents.availableAt, new Date()),
        notInEvents(excludeEvents)
      )
    )
    .orderBy(asc(ExternalGatewayAgentEvents.createdAt), asc(ExternalGatewayAgentEvents.providerEventId))
    .for('update')
    .limit(MAX_ADDRESSED_RECEIVE_BATCH_SIZE)

  const batch: Array<typeof ExternalGatewayAgentEvents.$inferSelect> = []
  for (const row of rows) {
    if (batch.length >= MAX_ADDRESSED_RECEIVE_BATCH_SIZE) break
    if (row.providerEventId !== first.providerEventId && row.actorKey !== first.actorKey) break
    batch.push(row)
  }

  return batch.length ? batch : [first]
}

/**
 * The key that groups addressed receives into one batch: same agent, binding,
 * room, and thread. Messages sharing it coalesce into a single agent turn.
 */
export function externalGatewayBatchKey(input: {
  agentUid: string
  bindingName: string
  providerRoomId: string
  providerThreadId: string
}): string {
  return JSON.stringify([input.agentUid, input.bindingName, input.providerRoomId, input.providerThreadId])
}

/**
 * The agent's conversation session id for one room. Scoped per room (not per
 * thread) so every exchange in a room threads into the same conversation.
 */
export function externalGatewaySessionId(agentUid: string, providerRoomId: string): string {
  return `${agentUid}:external-room:${providerRoomId}`
}

function agentEventKeyWhere(event: ExternalGatewayAgentEventKey) {
  return and(
    eq(ExternalGatewayAgentEvents.agentUid, event.agentUid),
    eq(ExternalGatewayAgentEvents.bindingName, event.bindingName),
    eq(ExternalGatewayAgentEvents.providerEventId, event.providerEventId)
  )
}

function agentEventKeysWhere(events: readonly ExternalGatewayAgentEventKey[]) {
  const predicates = events.map(agentEventKeyWhere)
  return predicates.length === 1 ? predicates[0]! : or(...predicates)
}

/** Excludes rows already claimed by an in-flight delivery. */
function notInEvents(events: readonly ExternalGatewayAgentEventKey[] | undefined) {
  if (!events || events.length === 0) return undefined
  return sql`not (${agentEventKeysWhere(events)})`
}

function isInFlightEvent(
  event: ExternalGatewayAgentEventKey,
  inFlightEvents: readonly ExternalGatewayAgentEventKey[] | undefined
): boolean {
  return Boolean(inFlightEvents?.some(inFlight => sameAgentEventKey(event, inFlight)))
}

function sameAgentEventKey(left: ExternalGatewayAgentEventKey, right: ExternalGatewayAgentEventKey): boolean {
  return (
    left.agentUid === right.agentUid &&
    left.bindingName === right.bindingName &&
    left.providerEventId === right.providerEventId
  )
}

/**
 * Predicate that hides delete/recall events whose receive is still in-flight.
 *
 * Ordering guard: a lifecycle event must not be delivered before the receive it
 * compensates has finished delivering, or the agent could see "this message was
 * recalled" before (or instead of) the message itself. So while a receive is
 * in-flight, its matching delete/recall rows are excluded from claiming and
 * become claimable again once the receive settles.
 */
function notLifecycleBlockedByInFlightReceives(events: readonly ExternalGatewayInFlightAgentEvent[] | undefined) {
  const receiveEvents = events?.filter(
    event => event.type === 'message.received' && typeof event.providerMessageId === 'string'
  )
  if (!receiveEvents || receiveEvents.length === 0) return undefined
  return sql`not (${or(
    ...receiveEvents.map(event =>
      and(
        eq(ExternalGatewayAgentEvents.agentUid, event.agentUid),
        eq(ExternalGatewayAgentEvents.bindingName, event.bindingName),
        eq(ExternalGatewayAgentEvents.providerRoomId, event.providerRoomId),
        eq(ExternalGatewayAgentEvents.providerMessageId, event.providerMessageId!),
        inArray(ExternalGatewayAgentEvents.type, ['message.deleted', 'message.recalled'])
      )
    )
  )})`
}

export class ExternalGatewayAgentEventQueueError extends Error {
  constructor(message: string) {
    super(message)
    this.name = 'ExternalGatewayAgentEventQueueError'
  }
}
