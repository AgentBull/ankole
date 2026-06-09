import { genUUIDv7 } from '@agentbull/bullx-native-addons'
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
import type { AiAgentCheckbacks, ScheduledTasks, SchedulerRunStatus } from '@/common/db-schema'
import { loadSystemTimezone } from '@/config/system'
import { computeNextRun } from './schedule'
import { createHeadlessAdapter } from './headless-adapter'
import { schedulerStore, type SchedulerStore, type ScheduledTaskTrigger } from './store'

const DEFAULT_LEASE_MS = 5 * 60_000
const DEFAULT_LEASE_HEARTBEAT_MS = 60_000
const FAILURE_BACKOFF_MS = [30_000, 60_000, 5 * 60_000, 15 * 60_000, 60 * 60_000] as const
const DEFAULT_FAILURE_ALERT_THRESHOLD = 3
const DEFAULT_FAILURE_ALERT_COOLDOWN_MS = 60 * 60_000

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

  constructor(private readonly store: SchedulerStore = schedulerStore) {}

  setAgentExecutor(executor: SchedulerAgentExecutor): void {
    this.agentExecutor = executor
  }

  setRuntimeTuningForTest(input: {
    failureAlertCooldownMs?: number
    failureAlertThreshold?: number
    leaseHeartbeatMs?: number
    leaseMs?: number
  }): void {
    this.failureAlertCooldownMs = input.failureAlertCooldownMs ?? this.failureAlertCooldownMs
    this.failureAlertThreshold = input.failureAlertThreshold ?? this.failureAlertThreshold
    this.leaseHeartbeatMs = input.leaseHeartbeatMs ?? this.leaseHeartbeatMs
    this.leaseMs = input.leaseMs ?? this.leaseMs
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
    let status: SchedulerRunStatus = 'failed'
    let result: AiAgentProgrammaticTurnResult | undefined
    let error: string | undefined
    try {
      status = await this.withLeaseHeartbeat(
        () => this.store.extendTaskLease(task.id, this.instanceId, this.leaseMs),
        async () => {
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
            suppressVisibleOutput: !delivery
          })
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

    const timezone = await loadSystemTimezone()
    const finishedAt = new Date()
    const nextRunAt = !task.enabled
      ? null
      : status === 'succeeded'
        ? computeNextRun({ schedule: task.schedule, after: finishedAt, taskId: task.id, timezone })
        : new Date(finishedAt.getTime() + backoffMs(task.consecutiveFailures))
    await this.store.completeTaskRun({
      conversationId: result?.conversationId,
      delivered: result?.enqueuedOutput ?? false,
      error,
      instanceId: this.instanceId,
      metadata: result ? checkbackCompletionMetadata(result) : {},
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
  return [
    '[check_back_later wakeup]',
    `Reason: ${checkback.reason}`,
    `Check: ${checkback.check}`,
    checkback.contextSummary ? `Context: ${checkback.contextSummary}` : ''
  ]
    .filter(Boolean)
    .join('\n')
}

function checkbackCompletionMetadata(result: AiAgentProgrammaticTurnResult): JsonObject {
  return {
    generation_status: result.status,
    enqueued_output: result.enqueuedOutput
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
  return status === 'succeeded' ? 'succeeded' : status === 'cancelled' || status === 'fenced' ? 'cancelled' : 'failed'
}

function backoffMs(consecutiveFailures: number): number {
  return FAILURE_BACKOFF_MS[Math.min(consecutiveFailures, FAILURE_BACKOFF_MS.length - 1)]!
}

function stringOrUndefined(value: unknown): string | undefined {
  return typeof value === 'string' && value.length > 0 ? value : undefined
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
