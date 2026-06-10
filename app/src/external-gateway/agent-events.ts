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

export interface ExternalGatewayAgentDelivery {
  events: Array<typeof ExternalGatewayAgentEvents.$inferSelect>
}

export type ExternalGatewayAgentEventKey = Pick<
  typeof ExternalGatewayAgentEvents.$inferSelect,
  'agentUid' | 'bindingName' | 'providerEventId'
>

export const NORMAL_RECEIVE_BATCH_WINDOW_MS = 75
const INPUT_TOMBSTONE_TTL_MS = ms('24h')
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
    })
  }

  async enqueueReceive(
    input: Omit<EnqueueExternalGatewayAgentEventInput, 'quietUntil' | 'type'>
  ): Promise<typeof ExternalGatewayAgentEvents.$inferSelect> {
    return this.enqueue({
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
    providerMessageId: string
    providerRoomId: string
    payload?: ExternalGatewayAgentEnvelope
    remove?: boolean
  }): Promise<'mutated' | 'removed' | 'not_pending'> {
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
    const rows = await DB.select({ providerMessageId: ExternalGatewayInputTombstones.providerMessageId })
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
   * Records a short-lived stale-receive guard for delete/recall-before-receive.
   */
  async recordInputTombstone(input: {
    agentUid: string
    bindingName: string
    providerMessageId: string
    providerRoomId: string
  }): Promise<void> {
    await DB.transaction(async tx => {
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

  async claimReady(
    input: {
      agentUids?: readonly string[]
      /** Events already claimed by an in-flight delivery; rows stay pending until markDone/markFailed. */
      excludeEvents?: readonly ExternalGatewayAgentEventKey[]
    } = {}
  ): Promise<ExternalGatewayAgentDelivery | undefined> {
    if (input.agentUids && input.agentUids.length === 0) return undefined

    return DB.transaction(async tx => {
      const readyPredicate = and(
        eq(ExternalGatewayAgentEvents.status, 'pending'),
        lte(ExternalGatewayAgentEvents.availableAt, new Date()),
        input.agentUids ? inArray(ExternalGatewayAgentEvents.agentUid, [...input.agentUids]) : undefined,
        notInEvents(input.excludeEvents)
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

  async nextPendingAvailableAt(
    input: {
      agentUids?: readonly string[]
      excludeEvents?: readonly ExternalGatewayAgentEventKey[]
    } = {}
  ): Promise<Date | undefined> {
    if (input.agentUids && input.agentUids.length === 0) return undefined

    const pendingPredicate = and(
      eq(ExternalGatewayAgentEvents.status, 'pending'),
      input.agentUids ? inArray(ExternalGatewayAgentEvents.agentUid, [...input.agentUids]) : undefined,
      notInEvents(input.excludeEvents)
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

export function externalGatewayBatchKey(input: {
  agentUid: string
  bindingName: string
  providerRoomId: string
  providerThreadId: string
}): string {
  return JSON.stringify([input.agentUid, input.bindingName, input.providerRoomId, input.providerThreadId])
}

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

export class ExternalGatewayAgentEventQueueError extends Error {
  constructor(message: string) {
    super(message)
    this.name = 'ExternalGatewayAgentEventQueueError'
  }
}
