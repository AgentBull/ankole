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
export type ScheduledTaskTrigger = 'schedule' | 'manual' | 'catchup'

export class SchedulerStore {
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

  async completeTaskRun(input: {
    conversationId?: string
    delivered: boolean
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
          lastRunAt: new Date(),
          previousRunAt: sql`${ScheduledTasks.nextRunAt}`,
          lastStatus: input.status === 'running' ? null : input.status,
          lastRunId: input.runId,
          consecutiveFailures: input.status === 'failed' ? sql`${ScheduledTasks.consecutiveFailures} + 1` : 0,
          claimedBy: null,
          claimedAt: null,
          leaseExpiresAt: null,
          updatedAt: sql`now()`
        })
        .where(and(eq(ScheduledTasks.id, input.taskId), eq(ScheduledTasks.claimedBy, input.instanceId)))
    })
  }

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
