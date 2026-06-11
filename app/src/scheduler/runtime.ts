import { genUUIDv7 } from '@agentbull/bullx-native-addons'
import { compact, isNonEmptyString, ms, match } from '@pleisto/active-support'
import type { Runtime } from '@/common/lifecycle'
import { logger } from '@/common/logger'
import type { JsonObject } from '@/common/db-schema'
import type { ExternalGatewayAgentExecutionContext } from '@/external-gateway/agent'
import { externalGatewayRuntime } from '@/external-gateway'
import { externalGatewayOutbox } from '@/external-gateway/outbox'
import { externalGatewayProjectionSink } from '@/external-gateway/core/projection'
import { aiAgentRuntime, type AiAgentProgrammaticTurnResult } from '@/ai-agent/runtime'
import { textFromContent } from '@/ai-agent/conversation-service'
import { getAgent, type AgentResult } from '@/principals/agents/service'
import { redactSensitiveText } from '@/security/redact'
import type { AiAgentCheckbacks, ScheduledTasks, SchedulerRunStatus } from '@/common/db-schema'
import { loadSystemTimezone } from '@/config/system'
import { computeNextRun } from './schedule'
import { createHeadlessAdapter } from './headless-adapter'
import { schedulerStore, type SchedulerStore, type ScheduledTaskTrigger } from './store'

const DEFAULT_LEASE_MS = ms('5m')
const DEFAULT_LEASE_HEARTBEAT_MS = ms('1m')
const FAILURE_BACKOFF_MS = [ms('30s'), ms('1m'), ms('5m'), ms('15m'), ms('1h')] as const
const DEFAULT_FAILURE_ALERT_THRESHOLD = 3
const DEFAULT_FAILURE_ALERT_COOLDOWN_MS = ms('1h')
const DEFAULT_TASK_RUN_TIMEOUT_MS = ms('30m')
const CRON_CATCHUP_MIN_GRACE_MS = ms('2m')
const CRON_CATCHUP_MAX_GRACE_MS = ms('2h')
const MAX_SCHEDULE_ERRORS = 3

export interface SchedulerRuntimeStats {
  instanceId: string
  started: boolean
}

export interface SchedulerAgentExecutor {
  runProgrammaticTurn: typeof aiAgentRuntime.runProgrammaticTurn
}

type ScheduledTaskRow = typeof ScheduledTasks.$inferSelect
type CheckbackRow = typeof AiAgentCheckbacks.$inferSelect

export class SchedulerRuntime implements Runtime<SchedulerRuntimeStats> {
  private readonly instanceId = genUUIDv7()
  private agentExecutor: SchedulerAgentExecutor = aiAgentRuntime
  private heartbeat?: { stop(): unknown; unref(): unknown }
  private tickPromise: Promise<void> | null = null
  private started = false
  private leaseMs = DEFAULT_LEASE_MS
  private leaseHeartbeatMs = DEFAULT_LEASE_HEARTBEAT_MS
  private failureAlertThreshold = DEFAULT_FAILURE_ALERT_THRESHOLD
  private failureAlertCooldownMs = DEFAULT_FAILURE_ALERT_COOLDOWN_MS
  private taskRunTimeoutMs = DEFAULT_TASK_RUN_TIMEOUT_MS

  constructor(private readonly store: SchedulerStore = schedulerStore) {}

  setAgentExecutor(executor: SchedulerAgentExecutor): void {
    this.agentExecutor = executor
  }

  setRuntimeTuningForTest(input: {
    failureAlertCooldownMs?: number
    failureAlertThreshold?: number
    leaseHeartbeatMs?: number
    leaseMs?: number
    taskRunTimeoutMs?: number
  }): void {
    this.failureAlertCooldownMs = input.failureAlertCooldownMs ?? this.failureAlertCooldownMs
    this.failureAlertThreshold = input.failureAlertThreshold ?? this.failureAlertThreshold
    this.leaseHeartbeatMs = input.leaseHeartbeatMs ?? this.leaseHeartbeatMs
    this.leaseMs = input.leaseMs ?? this.leaseMs
    this.taskRunTimeoutMs = input.taskRunTimeoutMs ?? this.taskRunTimeoutMs
  }

  async start(): Promise<SchedulerRuntimeStats> {
    if (this.started) return this.stats()
    this.started = true
    this.heartbeat = Bun.cron('* * * * *', () => {
      this.runTick('schedule').catch(error => {
        logger.error({ error }, 'Scheduler tick failed')
      })
    }) as unknown as { stop(): unknown; unref(): unknown }
    this.heartbeat.unref()
    logger.info(this.stats(), 'Scheduler runtime started')
    try {
      const recoveredRuns = await this.store.recoverOrphanedTaskRuns({
        error: 'scheduler runtime restarted before run completed',
        now: new Date(),
        retryAt: new Date(Date.now() + backoffMs(0))
      })
      if (recoveredRuns > 0) logger.warn({ recoveredRuns }, 'Recovered orphaned scheduler task runs')
    } catch (error) {
      logger.error({ error }, 'Scheduler orphaned task run recovery failed')
    }
    this.runTick('catchup').catch(error => {
      logger.error({ error }, 'Scheduler startup tick failed')
    })
    return this.stats()
  }

  async stop(): Promise<void> {
    this.started = false
    this.heartbeat?.stop()
    this.heartbeat = undefined
    if (this.tickPromise) await this.tickPromise.catch(() => undefined)
  }

  stats(): SchedulerRuntimeStats {
    return {
      instanceId: this.instanceId,
      started: this.started
    }
  }

  async runNow(taskId: string): Promise<void> {
    const task = await this.store.claimTaskNow(taskId, new Date(), this.instanceId, this.leaseMs)
    if (!task) return
    await this.executeScheduledTask(task, 'manual')
  }

  async runTick(trigger: Exclude<ScheduledTaskTrigger, 'manual'> = 'schedule'): Promise<void> {
    if (this.tickPromise) return this.tickPromise
    this.tickPromise = this.drainDue(trigger).finally(() => {
      this.tickPromise = null
    })
    return this.tickPromise
  }

  private async drainDue(trigger: Exclude<ScheduledTaskTrigger, 'manual'>): Promise<void> {
    while (this.started) {
      const checkback = await this.store.claimDueCheckback(new Date(), this.instanceId, this.leaseMs)
      if (!checkback) break
      await this.executeCheckback(checkback)
    }

    while (this.started) {
      const task = await this.store.claimDueTask(new Date(), this.instanceId, this.leaseMs)
      if (!task) break
      await this.executeScheduledTask(task, trigger)
    }
  }

  private async executeCheckback(checkback: CheckbackRow): Promise<void> {
    try {
      await this.withLeaseHeartbeat(
        () => this.store.extendCheckbackLease(checkback.id, this.instanceId, this.leaseMs),
        async () => {
          const agent = await requireActiveAgent(checkback.agentUid)
          const source = checkback.source
          const bindingName = String(source.binding_name)
          const providerRoomId = stringOrUndefined(source.provider_room_id)
          const providerThreadId = stringOrUndefined(source.provider_thread_id) ?? providerRoomId
          const context = executionContext({
            agent,
            bindingName,
            providerRealmId: stringOrUndefined(source.provider_realm_id),
            scheduleDrain: availableAt =>
              externalGatewayRuntime.triggerOutboxDrain(agent.agent.uid, bindingName, availableAt)
          })
          const result = await this.agentExecutor.runProgrammaticTurn(context, {
            conversationProviderRoomId: `checkback:${checkback.id}`,
            disableInteractiveTools: true,
            eventId: checkback.id,
            eventSource: 'ai-agent.check_back_later',
            kind: 'checkback_generation',
            message: checkbackMessage(checkback),
            metadata: {
              control: {
                type: 'check_back_later',
                checkback_id: checkback.id,
                source
              }
            },
            outputProviderRoomId: providerRoomId,
            outputProviderThreadId: providerThreadId,
            suppressVisibleOutput: !providerRoomId
          })
          if (result.enqueuedOutput && providerRoomId) {
            externalGatewayRuntime.triggerOutboxDrain(agent.agent.uid, bindingName)
          }
          await this.store.completeCheckback({
            checkbackId: checkback.id,
            conversationId: result.conversationId,
            instanceId: this.instanceId,
            metadata: checkbackCompletionMetadata(result),
            status: resultStatus(result.status),
            triggerMessageId: result.triggerMessageId
          })
        }
      )
    } catch (error) {
      await this.store.completeCheckback({
        checkbackId: checkback.id,
        error: errorMessage(error),
        instanceId: this.instanceId,
        status: 'failed'
      })
      logger.error({ error, checkbackId: checkback.id }, 'check_back_later execution failed')
    }
  }

  private async executeScheduledTask(task: ScheduledTaskRow, trigger: ScheduledTaskTrigger): Promise<void> {
    const scheduledFor = task.nextRunAt ?? new Date()
    const run = await this.store.createTaskRun({
      instanceId: this.instanceId,
      scheduledFor,
      task,
      trigger
    })
    const timezone = await loadSystemTimezone()
    let staleCatchup: ReturnType<typeof staleCronCatchup>
    try {
      staleCatchup = staleCronCatchup({ now: new Date(), scheduledFor, task, timezone, trigger })
    } catch (caught) {
      const finishedAt = new Date()
      const error = `schedule error: ${errorMessage(caught)}`
      const disableTask = task.consecutiveFailures + 1 >= MAX_SCHEDULE_ERRORS
      await this.store.completeTaskRun({
        delivered: false,
        disableTask,
        error,
        instanceId: this.instanceId,
        metadata: { schedule_error: true },
        nextRunAt: disableTask ? null : new Date(finishedAt.getTime() + backoffMs(task.consecutiveFailures)),
        runId: run.id,
        status: 'failed',
        taskId: task.id
      })
      await this.maybeRecordFailureAlert(task, error)
      logger.error({ error: caught, taskId: task.id, runId: run.id }, 'Scheduled task schedule calculation failed')
      return
    }
    if (staleCatchup) {
      await this.store.completeTaskRun({
        delivered: false,
        error: staleCatchup.reason,
        instanceId: this.instanceId,
        metadata: {
          catchup: {
            action: 'fast_forward',
            grace_ms: staleCatchup.graceMs,
            lateness_ms: staleCatchup.latenessMs,
            reason: staleCatchup.reason
          }
        },
        nextRunAt: staleCatchup.nextRunAt,
        runId: run.id,
        status: 'cancelled',
        taskId: task.id
      })
      return
    }
    let status: SchedulerRunStatus = 'failed'
    let result: AiAgentProgrammaticTurnResult | undefined
    let error: string | undefined
    let timedOut = false
    try {
      status = await this.withLeaseHeartbeat(
        () => this.store.extendTaskLease(task.id, this.instanceId, this.leaseMs),
        async () => {
          const timeout = scheduledTaskTimeoutSignal(this.taskRunTimeoutMs)
          const agent = await requireActiveAgent(task.agentUid)
          const delivery = task.delivery
          const bindingName = delivery?.binding_name ?? 'scheduler'
          const providerRoomId = delivery?.room_id
          const providerThreadId = delivery?.thread_id ?? providerRoomId
          const context = executionContext({
            agent,
            bindingName,
            scheduleDrain: availableAt => {
              if (delivery) externalGatewayRuntime.triggerOutboxDrain(agent.agent.uid, bindingName, availableAt)
            }
          })
          const eventId = scheduledTaskEventId(task.id, scheduledFor, trigger, run.id)
          try {
            result = await this.agentExecutor.runProgrammaticTurn(context, {
              conversationProviderRoomId: `scheduled-task:${task.id}`,
              disableInteractiveTools: true,
              eventId,
              eventSource: 'scheduler.task',
              kind: 'scheduled_task',
              message: task.payload.message,
              metadata: {
                control: {
                  type: 'scheduled_task',
                  task_id: task.id,
                  run_id: run.id,
                  trigger
                }
              },
              outputProviderRoomId: providerRoomId,
              outputProviderThreadId: providerThreadId,
              signal: timeout.signal,
              suppressVisibleOutput: !delivery
            })
          } finally {
            timedOut = timeout.signal.aborted
            timeout.cancel()
          }
          if (timedOut) {
            error = `scheduled task timed out after ${this.taskRunTimeoutMs}ms`
            return 'failed'
          }
          if (result.enqueuedOutput && delivery) {
            externalGatewayRuntime.triggerOutboxDrain(agent.agent.uid, bindingName)
          }
          return resultStatus(result.status)
        }
      )
    } catch (caught) {
      error = errorMessage(caught)
      logger.error({ error: caught, taskId: task.id, runId: run.id }, 'Scheduled task execution failed')
    }

    const finishedAt = new Date()
    let disableTask = false
    let nextRunAt: Date | null = null
    if (task.enabled) {
      if (status === 'succeeded') {
        try {
          nextRunAt = computeNextRun({ schedule: task.schedule, after: finishedAt, taskId: task.id, timezone })
        } catch (caught) {
          status = 'failed'
          error = `schedule error: ${errorMessage(caught)}`
          disableTask = task.consecutiveFailures + 1 >= MAX_SCHEDULE_ERRORS
          nextRunAt = disableTask ? null : new Date(finishedAt.getTime() + backoffMs(task.consecutiveFailures))
          logger.error({ error: caught, taskId: task.id, runId: run.id }, 'Scheduled task next-run calculation failed')
        }
      } else {
        nextRunAt = new Date(finishedAt.getTime() + backoffMs(task.consecutiveFailures))
      }
    }
    await this.store.completeTaskRun({
      conversationId: result?.conversationId,
      delivered: result?.enqueuedOutput ?? false,
      disableTask,
      error,
      instanceId: this.instanceId,
      metadata: result ? checkbackCompletionMetadata(result, timedOut) : {},
      nextRunAt,
      runId: run.id,
      status,
      taskId: task.id,
      triggerMessageId: result?.triggerMessageId
    })
    if (status !== 'succeeded') await this.maybeRecordFailureAlert(task, error)
  }

  private async withLeaseHeartbeat<T>(extend: () => Promise<boolean>, fn: () => Promise<T>): Promise<T> {
    let stopped = false
    const timer = setInterval(() => {
      if (stopped) return
      extend().catch(error => {
        logger.warn({ error }, 'Scheduler lease heartbeat failed')
      })
    }, this.leaseHeartbeatMs)
    timer.unref()
    try {
      return await fn()
    } finally {
      stopped = true
      clearInterval(timer)
    }
  }

  private async maybeRecordFailureAlert(task: ScheduledTaskRow, error?: string): Promise<void> {
    const nextFailureCount = task.consecutiveFailures + 1
    if (nextFailureCount < this.failureAlertThreshold) return

    const now = new Date()
    if (task.lastAlertAt && now.getTime() - task.lastAlertAt.getTime() < this.failureAlertCooldownMs) return

    await this.store.recordTaskFailureAlert(task.id, now)
    await this.enqueueFailureAlert(task, nextFailureCount, error, now).catch(caught => {
      logger.error({ error: caught, taskId: task.id }, 'Failed to enqueue scheduled task failure alert')
    })
    logger.warn(
      {
        agentUid: task.agentUid,
        consecutiveFailures: nextFailureCount,
        error,
        taskId: task.id,
        taskName: task.name
      },
      'Scheduled task reached consecutive failure alert threshold'
    )
  }

  private async enqueueFailureAlert(
    task: ScheduledTaskRow,
    consecutiveFailures: number,
    error: string | undefined,
    now: Date
  ): Promise<void> {
    const delivery = task.delivery
    if (!delivery) return
    const bindingName = delivery.binding_name
    const providerRoomId = delivery.room_id
    const providerThreadId = delivery.thread_id ?? providerRoomId
    if (!bindingName || !providerRoomId) return
    const lastError = redactSensitiveText((error?.trim() || 'unknown reason').slice(0, 200))
    const text = [
      `Scheduled task "${task.name}" failed ${consecutiveFailures} times.`,
      `Last error: ${lastError}`
    ].join('\n')
    await externalGatewayOutbox.enqueuePending({
      agentUid: task.agentUid,
      bindingName,
      intent: {
        finalPayload: { text },
        operation: 'post',
        outboundKey: `scheduler-failure-alert:${task.id}:${now.toISOString()}`,
        providerRoomId,
        providerThreadId
      }
    })
    externalGatewayRuntime.triggerOutboxDrain(task.agentUid, bindingName)
  }
}

export const schedulerRuntime = new SchedulerRuntime()

function executionContext(input: {
  agent: AgentResult
  bindingName: string
  providerRealmId?: string
  scheduleDrain: (availableAt?: Date) => void
}): ExternalGatewayAgentExecutionContext {
  return {
    adapter: createHeadlessAdapter(`scheduler:${input.bindingName}`),
    agent: input.agent,
    agentUid: input.agent.agent.uid,
    bindingName: input.bindingName,
    outbox: externalGatewayOutbox,
    projection: externalGatewayProjectionSink,
    providerRealmId: input.providerRealmId,
    scheduleOutboxDrain: input.scheduleDrain
  }
}

async function requireActiveAgent(agentUid: string): Promise<AgentResult> {
  const agent = await getAgent(agentUid)
  if (!agent || agent.principal.status !== 'active') throw new SchedulerRuntimeError(`agent not found: ${agentUid}`)
  return agent
}

function checkbackMessage(checkback: CheckbackRow): string {
  const wakeText = textFromContent(checkback.wakeMessage)
  if (wakeText.trim()) return wakeText
  return compact([
    '[check_back_later wakeup]',
    'This is a one-shot delayed wakeup, not a recurring heartbeat.',
    'The check below is the current task. Use the context as background only.',
    'Do not infer or repeat old tasks from prior chats.',
    "If nothing needs the user's attention, do not send a visible message.",
    'Send a visible message only when the user should be interrupted: meaningful result, blocker, needed decision, or time-sensitive risk.',
    `Reason: ${checkback.reason}`,
    `Check: ${checkback.check}`,
    checkback.contextSummary ? `Context: ${checkback.contextSummary}` : ''
  ]).join('\n')
}

function checkbackCompletionMetadata(result: AiAgentProgrammaticTurnResult, timedOut = false): JsonObject {
  return {
    generation_status: result.status,
    enqueued_output: result.enqueuedOutput,
    timed_out: timedOut
  }
}

function scheduledTaskTimeoutSignal(timeoutMs: number): { signal: AbortSignal; cancel(): void } {
  const controller = new AbortController()
  const timer = setTimeout(
    () => controller.abort(new Error(`scheduled task timed out after ${timeoutMs}ms`)),
    timeoutMs
  )
  timer.unref?.()
  return {
    signal: controller.signal,
    cancel: () => clearTimeout(timer)
  }
}

function scheduledTaskEventId(
  taskId: string,
  scheduledFor: Date,
  trigger: ScheduledTaskTrigger,
  runId: string
): string {
  return trigger === 'manual' ? runId : `${taskId}:${scheduledFor.toISOString()}`
}

function resultStatus(status: AiAgentProgrammaticTurnResult['status']): Exclude<SchedulerRunStatus, 'running'> {
  return match(status)
    .with('succeeded', () => 'succeeded' as const)
    .with('cancelled', 'fenced', () => 'cancelled' as const)
    .otherwise(() => 'failed' as const)
}

function backoffMs(consecutiveFailures: number): number {
  return FAILURE_BACKOFF_MS[Math.min(consecutiveFailures, FAILURE_BACKOFF_MS.length - 1)]!
}

function staleCronCatchup(input: {
  now: Date
  scheduledFor: Date
  task: ScheduledTaskRow
  timezone: string
  trigger: ScheduledTaskTrigger
}): { graceMs: number; latenessMs: number; nextRunAt: Date; reason: string } | undefined {
  if (input.trigger !== 'catchup' || input.task.schedule.kind !== 'cron') return undefined
  const followingRun = computeNextRun({
    schedule: input.task.schedule,
    after: input.scheduledFor,
    taskId: input.task.id,
    timezone: input.timezone
  })
  const periodMs = Math.max(0, followingRun.getTime() - input.scheduledFor.getTime())
  const graceMs = Math.max(CRON_CATCHUP_MIN_GRACE_MS, Math.min(CRON_CATCHUP_MAX_GRACE_MS, Math.floor(periodMs / 2)))
  const latenessMs = input.now.getTime() - input.scheduledFor.getTime()
  if (latenessMs <= graceMs) return undefined
  return {
    graceMs,
    latenessMs,
    nextRunAt: computeNextRun({
      schedule: input.task.schedule,
      after: input.now,
      taskId: input.task.id,
      timezone: input.timezone
    }),
    reason: 'cron_catchup_stale_fast_forward'
  }
}

function stringOrUndefined(value: unknown): string | undefined {
  return isNonEmptyString(value) ? value : undefined
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}

export class SchedulerRuntimeError extends Error {
  constructor(message: string) {
    super(message)
    this.name = 'SchedulerRuntimeError'
  }
}
