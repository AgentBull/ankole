import { genUUIDv7 } from '@agentbull/bullx-native-addons'
import { and, asc, desc, eq, isNull, lt, lte, or, sql } from 'drizzle-orm'
import { DB, jsonbParam } from '@/common/database'
import {
  AiAgentCheckbacks,
  ScheduledTaskRuns,
  ScheduledTasks,
  type AiAgentCheckbackSource,
  type AiAgentCheckbackStatus,
  type JsonObject,
  type JsonValue,
  type ScheduledTaskDelivery,
  type ScheduledTaskPayload,
  type ScheduledTaskSchedule,
  type SchedulerRunStatus
} from '@/common/db-schema'

export type ClaimedCheckback = typeof AiAgentCheckbacks.$inferSelect
export type ClaimedScheduledTask = typeof ScheduledTasks.$inferSelect
/**
 * How a run was started: by the recurring `schedule`, by an operator pressing
 * `manual` "run now", or by `catchup` on startup when due tasks were missed
 * while the instance was down.
 */
export type ScheduledTaskTrigger = 'schedule' | 'manual' | 'catchup'

/**
 * All database access for the scheduler. Every claim here is lease-based: a row
 * is "owned" only while its `leaseExpiresAt` is in the future and `claimedBy`
 * matches the instance. Ownership lives in the lease, not in row existence, so a
 * peer that crashes can have its work safely taken over once the lease lapses
 * without two instances ever running the same task at once.
 */
export class SchedulerStore {
  /** Inserts a new pending checkback (a one-shot delayed agent wakeup). */
  async createCheckback(input: {
    agentUid: string
    check: string
    contextSummary?: string | null
    dueAt: Date
    reason: string
    source: AiAgentCheckbackSource
    timezone: string
    wakeMessage: JsonValue[]
  }): Promise<typeof AiAgentCheckbacks.$inferSelect> {
    const [row] = await DB.insert(AiAgentCheckbacks)
      .values({
        id: genUUIDv7(),
        agentUid: input.agentUid,
        dueAt: input.dueAt,
        timezone: input.timezone,
        status: 'pending',
        reason: input.reason,
        check: input.check,
        contextSummary: input.contextSummary ?? null,
        source: jsonbParam(input.source),
        wakeMessage: jsonbParam(input.wakeMessage)
      })
      .returning()
    if (!row) throw new SchedulerStoreError('Failed to create checkback')
    return row
  }

  /**
   * Atomically claims the most overdue checkback for this instance, or returns
   * nothing when none is due.
   *
   * A candidate is eligible when it is still `pending`, or `running` with an
   * expired lease (its previous owner died mid-run). `skipLocked` lets parallel
   * pollers step over a row another transaction already holds instead of
   * blocking, so several instances drain the queue without contending on the
   * same head row. The same eligibility predicate is repeated on the UPDATE as a
   * compare-and-set fence: it guarantees we only flip a row we are still allowed
   * to claim, even though the row lock already makes that the common case.
   */
  async claimDueCheckback(now: Date, instanceId: string, leaseMs: number): Promise<ClaimedCheckback | undefined> {
    return DB.transaction(async tx => {
      const [candidate] = await tx
        .select()
        .from(AiAgentCheckbacks)
        .where(
          and(
            lte(AiAgentCheckbacks.dueAt, now),
            or(
              eq(AiAgentCheckbacks.status, 'pending'),
              and(eq(AiAgentCheckbacks.status, 'running'), lt(AiAgentCheckbacks.leaseExpiresAt, now))
            )
          )
        )
        .orderBy(asc(AiAgentCheckbacks.dueAt), asc(AiAgentCheckbacks.createdAt))
        .for('update', { skipLocked: true })
        .limit(1)
      if (!candidate) return undefined

      const [claimed] = await tx
        .update(AiAgentCheckbacks)
        .set({
          status: 'running',
          claimedBy: instanceId,
          claimedAt: now,
          leaseExpiresAt: new Date(now.getTime() + leaseMs),
          updatedAt: sql`now()`
        })
        .where(
          and(
            eq(AiAgentCheckbacks.id, candidate.id),
            or(
              eq(AiAgentCheckbacks.status, 'pending'),
              and(eq(AiAgentCheckbacks.status, 'running'), lt(AiAgentCheckbacks.leaseExpiresAt, now))
            )
          )
        )
        .returning()
      return claimed
    })
  }

  /**
   * Writes the terminal status of a checkback and releases its lease.
   *
   * The `claimedBy = instanceId` guard in the WHERE clause is the important part:
   * if our lease already expired and another instance took the checkback over,
   * this update matches nothing and we do not clobber the new owner's state.
   */
  async completeCheckback(input: {
    checkbackId: string
    conversationId?: string
    error?: string | null
    instanceId: string
    metadata?: JsonObject
    status: Exclude<AiAgentCheckbackStatus, 'pending' | 'running'>
    triggerMessageId?: string
  }): Promise<void> {
    await DB.update(AiAgentCheckbacks)
      .set({
        status: input.status,
        conversationId: input.conversationId ?? null,
        triggerMessageId: input.triggerMessageId ?? null,
        completedAt: new Date(),
        claimedBy: null,
        claimedAt: null,
        leaseExpiresAt: null,
        error: input.error ?? null,
        metadata: jsonbParam(input.metadata ?? {}),
        updatedAt: sql`now()`
      })
      .where(and(eq(AiAgentCheckbacks.id, input.checkbackId), eq(AiAgentCheckbacks.claimedBy, input.instanceId)))
  }

  /**
   * Pushes the checkback lease forward while we are still working on it.
   *
   * Returns false when the row no longer belongs to us (the heartbeat lost a
   * race and someone else now holds it), which the caller uses to detect that it
   * has been fenced out and should stop.
   */
  async extendCheckbackLease(checkbackId: string, instanceId: string, leaseMs: number): Promise<boolean> {
    const [row] = await DB.update(AiAgentCheckbacks)
      .set({
        leaseExpiresAt: new Date(Date.now() + leaseMs),
        updatedAt: sql`now()`
      })
      .where(and(eq(AiAgentCheckbacks.id, checkbackId), eq(AiAgentCheckbacks.claimedBy, instanceId)))
      .returning({ id: AiAgentCheckbacks.id })
    return row !== undefined
  }

  async listTasks(agentUid: string): Promise<Array<typeof ScheduledTasks.$inferSelect>> {
    return DB.select()
      .from(ScheduledTasks)
      .where(eq(ScheduledTasks.agentUid, agentUid))
      .orderBy(asc(ScheduledTasks.name))
  }

  async getTask(taskId: string): Promise<typeof ScheduledTasks.$inferSelect | undefined> {
    const [task] = await DB.select().from(ScheduledTasks).where(eq(ScheduledTasks.id, taskId)).limit(1)
    return task
  }

  async createTask(input: {
    agentUid: string
    delivery?: ScheduledTaskDelivery | null
    enabled?: boolean
    id?: string
    name: string
    nextRunAt: Date | null
    payload: ScheduledTaskPayload
    schedule: ScheduledTaskSchedule
  }): Promise<typeof ScheduledTasks.$inferSelect> {
    const [task] = await DB.insert(ScheduledTasks)
      .values({
        id: input.id ?? genUUIDv7(),
        agentUid: input.agentUid,
        name: input.name,
        enabled: input.enabled ?? true,
        schedule: jsonbParam(input.schedule),
        payload: jsonbParam(input.payload),
        delivery: input.delivery ? jsonbParam(input.delivery) : null,
        nextRunAt: input.nextRunAt
      })
      .returning()
    if (!task) throw new SchedulerStoreError('Failed to create scheduled task')
    return task
  }

  /**
   * Applies a partial update to a task, touching only the fields provided.
   *
   * `name`, `enabled`, `schedule`, and `payload` patch only when a value is
   * given. `delivery` and `nextRunAt` instead branch on key *presence* (`in`):
   * passing them explicitly — even as null — is a deliberate "clear this field",
   * which must be distinguishable from "leave it untouched".
   */
  async updateTask(input: {
    delivery?: ScheduledTaskDelivery | null
    enabled?: boolean
    name?: string
    nextRunAt?: Date | null
    payload?: ScheduledTaskPayload
    schedule?: ScheduledTaskSchedule
    taskId: string
  }): Promise<typeof ScheduledTasks.$inferSelect> {
    const patch: Partial<typeof ScheduledTasks.$inferInsert> = { updatedAt: sql`now()` as never }
    if (input.name !== undefined) patch.name = input.name
    if (input.enabled !== undefined) patch.enabled = input.enabled
    if (input.schedule !== undefined) patch.schedule = jsonbParam(input.schedule) as never
    if (input.payload !== undefined) patch.payload = jsonbParam(input.payload) as never
    if ('delivery' in input) patch.delivery = input.delivery ? (jsonbParam(input.delivery) as never) : null
    if ('nextRunAt' in input) patch.nextRunAt = input.nextRunAt ?? null

    const [task] = await DB.update(ScheduledTasks).set(patch).where(eq(ScheduledTasks.id, input.taskId)).returning()
    if (!task) throw new SchedulerStoreError(`Unknown scheduled task: ${input.taskId}`)
    return task
  }

  async deleteTask(taskId: string): Promise<void> {
    await DB.delete(ScheduledTasks).where(eq(ScheduledTasks.id, taskId))
  }

  async listRuns(taskId: string, limit = 50): Promise<Array<typeof ScheduledTaskRuns.$inferSelect>> {
    return DB.select()
      .from(ScheduledTaskRuns)
      .where(eq(ScheduledTaskRuns.taskId, taskId))
      .orderBy(desc(ScheduledTaskRuns.startedAt), desc(ScheduledTaskRuns.id))
      .limit(limit)
  }

  /**
   * Atomically claims the next enabled, due task for this instance.
   *
   * Eligibility is "enabled, `nextRunAt` reached, and either never claimed
   * (`claimedBy` null) or claimed by an instance whose lease has lapsed". Same
   * select-for-update-skip-locked then compare-and-set shape as
   * {@link claimDueCheckback}: `skipLocked` lets pollers fan out without
   * blocking, and repeating the predicate on the UPDATE fences the claim.
   */
  async claimDueTask(now: Date, instanceId: string, leaseMs: number): Promise<ClaimedScheduledTask | undefined> {
    return DB.transaction(async tx => {
      const [candidate] = await tx
        .select()
        .from(ScheduledTasks)
        .where(
          and(
            eq(ScheduledTasks.enabled, true),
            lte(ScheduledTasks.nextRunAt, now),
            or(isNull(ScheduledTasks.claimedBy), lt(ScheduledTasks.leaseExpiresAt, now))
          )
        )
        .orderBy(asc(ScheduledTasks.nextRunAt), asc(ScheduledTasks.createdAt))
        .for('update', { skipLocked: true })
        .limit(1)
      if (!candidate) return undefined

      const [claimed] = await tx
        .update(ScheduledTasks)
        .set({
          claimedBy: instanceId,
          claimedAt: now,
          leaseExpiresAt: new Date(now.getTime() + leaseMs),
          updatedAt: sql`now()`
        })
        .where(
          and(
            eq(ScheduledTasks.id, candidate.id),
            or(isNull(ScheduledTasks.claimedBy), lt(ScheduledTasks.leaseExpiresAt, now))
          )
        )
        .returning()
      return claimed
    })
  }

  /**
   * Claims a specific task for an operator-triggered "run now", bypassing the
   * `enabled` and `nextRunAt` due checks that {@link claimDueTask} enforces.
   *
   * The lease guard is still applied (only an unclaimed or lease-lapsed task is
   * taken), so a manual run cannot stomp a run already in flight on another
   * instance. Returns nothing when the task is currently leased elsewhere.
   */
  async claimTaskNow(
    taskId: string,
    now: Date,
    instanceId: string,
    leaseMs: number
  ): Promise<ClaimedScheduledTask | undefined> {
    const [claimed] = await DB.update(ScheduledTasks)
      .set({
        claimedBy: instanceId,
        claimedAt: now,
        leaseExpiresAt: new Date(now.getTime() + leaseMs),
        updatedAt: sql`now()`
      })
      .where(
        and(eq(ScheduledTasks.id, taskId), or(isNull(ScheduledTasks.claimedBy), lt(ScheduledTasks.leaseExpiresAt, now)))
      )
      .returning()
    return claimed
  }

  /**
   * Heartbeats a task lease forward mid-run. Returns false when the row is no
   * longer ours, signalling the caller it has been fenced and should abandon the
   * run rather than keep writing on top of the new owner.
   */
  async extendTaskLease(taskId: string, instanceId: string, leaseMs: number): Promise<boolean> {
    const [row] = await DB.update(ScheduledTasks)
      .set({
        leaseExpiresAt: new Date(Date.now() + leaseMs),
        updatedAt: sql`now()`
      })
      .where(and(eq(ScheduledTasks.id, taskId), eq(ScheduledTasks.claimedBy, instanceId)))
      .returning({ id: ScheduledTasks.id })
    return row !== undefined
  }

  /** Opens a `running` run row that records this attempt; closed later by {@link completeTaskRun}. */
  async createTaskRun(input: {
    instanceId: string
    scheduledFor: Date
    task: typeof ScheduledTasks.$inferSelect
    trigger: ScheduledTaskTrigger
  }): Promise<typeof ScheduledTaskRuns.$inferSelect> {
    const [run] = await DB.insert(ScheduledTaskRuns)
      .values({
        id: genUUIDv7(),
        taskId: input.task.id,
        agentUid: input.task.agentUid,
        scheduledFor: input.scheduledFor,
        status: 'running',
        trigger: input.trigger,
        runByInstance: input.instanceId
      })
      .returning()
    if (!run) throw new SchedulerStoreError('Failed to create scheduled task run')
    return run
  }

  /**
   * Closes a run and advances its parent task in one transaction.
   *
   * The two writes must commit together: the run gets its terminal status while
   * the task gets re-armed (or disabled), its lease released, and its failure
   * counter updated. The task UPDATE is fenced on `claimedBy = instanceId`, so a
   * heartbeat we already lost mid-run cannot let this method overwrite the state
   * of whichever instance took the task over.
   */
  async completeTaskRun(input: {
    conversationId?: string
    delivered: boolean
    disableTask?: boolean
    error?: string | null
    metadata?: JsonObject
    nextRunAt: Date | null
    runId: string
    status: SchedulerRunStatus
    taskId: string
    instanceId: string
    triggerMessageId?: string
  }): Promise<void> {
    await DB.transaction(async tx => {
      await tx
        .update(ScheduledTaskRuns)
        .set({
          status: input.status,
          finishedAt: new Date(),
          conversationId: input.conversationId ?? null,
          triggerMessageId: input.triggerMessageId ?? null,
          delivered: input.delivered,
          error: input.error ?? null,
          metadata: jsonbParam(input.metadata ?? {}),
          updatedAt: sql`now()`
        })
        .where(eq(ScheduledTaskRuns.id, input.runId))

      await tx
        .update(ScheduledTasks)
        .set({
          nextRunAt: input.nextRunAt,
          // Leaves `enabled` untouched unless the caller asks to disable (e.g.
          // too many schedule-calculation errors); a normal run must not flip it.
          enabled: input.disableTask ? false : sql`${ScheduledTasks.enabled}`,
          lastRunAt: new Date(),
          // Snapshots the fire time we just serviced before `nextRunAt` is overwritten.
          previousRunAt: sql`${ScheduledTasks.nextRunAt}`,
          lastStatus: input.status === 'running' ? null : input.status,
          lastRunId: input.runId,
          // Counts consecutive failures for the alert threshold; any non-failure
          // outcome (success or cancelled catch-up) resets the streak to zero.
          consecutiveFailures: input.status === 'failed' ? sql`${ScheduledTasks.consecutiveFailures} + 1` : 0,
          claimedBy: null,
          claimedAt: null,
          leaseExpiresAt: null,
          updatedAt: sql`now()`
        })
        .where(and(eq(ScheduledTasks.id, input.taskId), eq(ScheduledTasks.claimedBy, input.instanceId)))
    })
  }

  /**
   * Fails out runs whose owning instance died and re-arms their tasks for retry.
   *
   * Called on each scheduler tick (not just startup) because a peer that crashes
   * only becomes recoverable once its lease expires. Processed in a bounded
   * batch so one sweep cannot lock an unbounded number of rows; the next tick
   * picks up any remainder.
   *
   * @returns How many orphaned runs were recovered in this batch.
   */
  async recoverOrphanedTaskRuns(input: { error: string; now: Date; retryAt: Date }): Promise<number> {
    return DB.transaction(async tx => {
      // Only runs whose owning task lease has lapsed are genuine orphans (the
      // instance executing them died). A run on a *live* peer keeps its task lease
      // heartbeated (see SchedulerRuntime.withLeaseHeartbeat / claimDueTask), so it
      // is excluded here: recovering an actively-leased run would kill a healthy
      // in-flight run and re-arm the task, double-delivering during a rolling deploy
      // where the old and new instances briefly overlap.
      const runs = await tx
        .select({
          id: ScheduledTaskRuns.id,
          taskId: ScheduledTaskRuns.taskId
        })
        .from(ScheduledTaskRuns)
        .innerJoin(ScheduledTasks, eq(ScheduledTasks.id, ScheduledTaskRuns.taskId))
        .where(
          and(
            eq(ScheduledTaskRuns.status, 'running'),
            or(isNull(ScheduledTasks.claimedBy), lt(ScheduledTasks.leaseExpiresAt, input.now))
          )
        )
        .for('update', { skipLocked: true })
        .limit(1000)

      for (const run of runs) {
        await tx
          .update(ScheduledTaskRuns)
          .set({
            status: 'failed',
            finishedAt: input.now,
            error: input.error,
            metadata: jsonbParam({ recovered_orphan: true }),
            updatedAt: sql`now()`
          })
          .where(and(eq(ScheduledTaskRuns.id, run.id), eq(ScheduledTaskRuns.status, 'running')))

        await tx
          .update(ScheduledTasks)
          .set({
            // Re-arms with the backoff `retryAt` only when the current fire time
            // is missing or already due. A `nextRunAt` still in the future was
            // set deliberately (e.g. an edit while the run was orphaned) and is
            // left intact instead of being dragged earlier.
            nextRunAt: sql`case when ${ScheduledTasks.nextRunAt} is null or ${ScheduledTasks.nextRunAt} <= ${input.now} then ${input.retryAt} else ${ScheduledTasks.nextRunAt} end`,
            lastRunAt: input.now,
            previousRunAt: sql`${ScheduledTasks.nextRunAt}`,
            lastStatus: 'failed',
            lastRunId: run.id,
            consecutiveFailures: sql`${ScheduledTasks.consecutiveFailures} + 1`,
            claimedBy: null,
            claimedAt: null,
            leaseExpiresAt: null,
            updatedAt: sql`now()`
          })
          .where(eq(ScheduledTasks.id, run.taskId))
      }

      return runs.length
    })
  }

  /** Stamps when a failure alert was last sent, so the cooldown can suppress repeats. */
  async recordTaskFailureAlert(taskId: string, alertedAt: Date): Promise<void> {
    await DB.update(ScheduledTasks)
      .set({
        lastAlertAt: alertedAt,
        updatedAt: sql`now()`
      })
      .where(eq(ScheduledTasks.id, taskId))
  }
}

export const schedulerStore = new SchedulerStore()

export class SchedulerStoreError extends Error {
  constructor(message: string) {
    super(message)
    this.name = 'SchedulerStoreError'
  }
}
