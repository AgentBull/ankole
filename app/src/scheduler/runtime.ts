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

// How long a claim owns a task/checkback before it is considered abandoned. The
// heartbeat below renews it well inside this window; if the owner dies, a peer
// may take over only after it lapses.
const DEFAULT_LEASE_MS = ms('5m')
// How often a running task renews its lease. Must stay comfortably under the
// lease duration so a brief stall does not look like a crash to other instances.
const DEFAULT_LEASE_HEARTBEAT_MS = ms('1m')
// Exponential-ish backoff between retries, indexed by consecutive-failure count.
// The last entry (1h) is the ceiling; further failures keep retrying hourly.
const FAILURE_BACKOFF_MS = [ms('30s'), ms('1m'), ms('5m'), ms('15m'), ms('1h')] as const
// Consecutive failures required before a task starts alerting its owner.
const DEFAULT_FAILURE_ALERT_THRESHOLD = 3
// Minimum gap between two failure alerts for the same task, so a task stuck in a
// fast retry loop does not spam the operator on every attempt.
const DEFAULT_FAILURE_ALERT_COOLDOWN_MS = ms('1h')
// Wall-clock budget for a single task run; exceeding it aborts the agent turn.
const DEFAULT_TASK_RUN_TIMEOUT_MS = ms('30m')
// Bounds on the catch-up grace window: a startup run that is overdue by more
// than the grace is fast-forwarded instead of executed (see staleCronCatchup).
const CRON_CATCHUP_MIN_GRACE_MS = ms('2m')
const CRON_CATCHUP_MAX_GRACE_MS = ms('2h')
// Schedule-math errors (bad cron, never-fires) tolerated in a row before the
// task is disabled, so a permanently broken schedule cannot retry forever.
const MAX_SCHEDULE_ERRORS = 3

export interface SchedulerRuntimeStats {
  instanceId: string
  started: boolean
}

/**
 * The single agent-execution dependency the scheduler needs. Narrowing it to
 * just `runProgrammaticTurn` lets tests swap in a fake executor without standing
 * up the whole AI agent runtime.
 */
export interface SchedulerAgentExecutor {
  runProgrammaticTurn: typeof aiAgentRuntime.runProgrammaticTurn
}

type ScheduledTaskRow = typeof ScheduledTasks.$inferSelect
type CheckbackRow = typeof AiAgentCheckbacks.$inferSelect

/**
 * Drives all scheduled work for one installation: it ticks once a minute, claims
 * any due tasks and checkbacks, runs each as a headless agent turn, and records
 * the outcome.
 *
 * Concurrency safety rests on per-row leases held in the database, not on this
 * process being the only one running. Each claim takes a time-boxed lease; a
 * heartbeat renews it for as long as the run lasts; and every tick first sweeps
 * runs whose owner died (lease lapsed) back into the queue. This lets several
 * instances — or an old and new instance during a rolling deploy — coexist
 * without ever double-processing the same task.
 */
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

  /**
   * Starts the once-a-minute tick loop and performs the startup recovery sweep.
   *
   * Idempotent: a second call while already started just returns current stats.
   * Startup does two things before normal ticking: it recovers runs orphaned by
   * the restart, then fires one `catchup` tick so tasks that came due while the
   * process was down are serviced (or fast-forwarded) immediately rather than
   * waiting up to a minute for the first scheduled tick.
   */
  async start(): Promise<SchedulerRuntimeStats> {
    if (this.started) return this.stats()
    this.started = true
    this.heartbeat = Bun.cron('* * * * *', () => {
      this.runTick('schedule').catch(error => {
        logger.error({ error }, 'Scheduler tick failed')
      })
    }) as unknown as { stop(): unknown; unref(): unknown }
    // Detaches the cron timer from the event loop so it never by itself keeps the
    // process alive during shutdown.
    this.heartbeat.unref()
    logger.info(this.stats(), 'Scheduler runtime started')
    await this.recoverOrphans('scheduler runtime restarted before run completed')
    this.runTick('catchup').catch(error => {
      logger.error({ error }, 'Scheduler startup tick failed')
    })
    return this.stats()
  }

  /**
   * Stops scheduling new ticks and waits for an in-flight tick to settle.
   *
   * Clearing `started` first makes the drain loops break after their current
   * item, so shutdown does not start more work; the await then lets the current
   * run finish cleanly. Errors from that final tick are swallowed because we are
   * tearing down regardless.
   */
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

  /**
   * Runs one task immediately on operator request. Silently does nothing when
   * the task cannot be claimed — it is currently leased by another run — so a
   * "run now" press never collides with an in-flight execution.
   */
  async runNow(taskId: string): Promise<void> {
    const task = await this.store.claimTaskNow(taskId, new Date(), this.instanceId, this.leaseMs)
    if (!task) return
    await this.executeScheduledTask(task, 'manual')
  }

  /**
   * Runs one drain pass, coalescing overlapping calls.
   *
   * A tick can take longer than the one-minute cron interval (a slow agent
   * turn), so the next cron fire would otherwise start a second concurrent
   * drain. Returning the in-flight promise instead serializes ticks: callers
   * await the same pass rather than launching a competing one.
   */
  async runTick(trigger: Exclude<ScheduledTaskTrigger, 'manual'> = 'schedule'): Promise<void> {
    if (this.tickPromise) return this.tickPromise
    this.tickPromise = this.drainDue(trigger).finally(() => {
      this.tickPromise = null
    })
    return this.tickPromise
  }

  // Recovers orphaned runs and logs the count, swallowing errors so a recovery
  // failure never aborts the tick that called it.
  private async recoverOrphans(reason: string): Promise<void> {
    try {
      const recoveredRuns = await this.store.recoverOrphanedTaskRuns({
        error: reason,
        now: new Date(),
        retryAt: new Date(Date.now() + backoffMs(0))
      })
      if (recoveredRuns > 0) logger.warn({ recoveredRuns }, 'Recovered orphaned scheduler task runs')
    } catch (error) {
      logger.error({ error }, 'Scheduler orphaned task run recovery failed')
    }
  }

  /**
   * Drains everything currently due: first orphan recovery, then checkbacks, then
   * tasks. Each phase re-claims one item at a time and stops when none is left or
   * the runtime is shutting down.
   *
   * Items are claimed one-by-one rather than batch-fetched so the lease is taken
   * at execution time: a slow earlier item never lets a later item's lease go
   * stale while it waits in a pre-fetched list.
   */
  private async drainDue(trigger: Exclude<ScheduledTaskTrigger, 'manual'>): Promise<void> {
    // Recover runs whose owning instance died (lease lapsed) every tick, not just
    // at startup: a peer that crashed after we booted only becomes recoverable once
    // its lease expires, and a single-instance ungraceful crash leaves its own lease
    // valid for up to leaseMs after restart.
    await this.recoverOrphans('owning scheduler instance lease expired before run completed')

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

  /**
   * Runs one `check_back_later` wakeup as a headless agent turn and records the
   * outcome.
   *
   * The work runs under a lease heartbeat so a long turn keeps ownership. Any
   * failure is caught and written back as `failed` (still fenced to this
   * instance), so a thrown error releases the lease cleanly instead of leaving
   * the checkback stuck in `running` until its lease lapses.
   */
  private async executeCheckback(checkback: CheckbackRow): Promise<void> {
    try {
      await this.withLeaseHeartbeat(
        () => this.store.extendCheckbackLease(checkback.id, this.instanceId, this.leaseMs),
        async () => {
          const agent = await requireActiveAgent(checkback.agentUid)
          const source = checkback.source
          const bindingName = String(source.binding_name)
          const providerRoomId = stringOrUndefined(source.provider_room_id)
          // Falls back to the room id when no thread is recorded, so a reply lands
          // in the originating room rather than nowhere.
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
            // With no room to deliver to, the turn runs for its side effects only
            // and any would-be chat message is suppressed rather than dropped late.
            suppressVisibleOutput: !providerRoomId
          })
          // The agent only enqueued output; nudge the outbox to deliver it now
          // instead of waiting for its next natural drain.
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

  /**
   * Runs one scheduled task end to end: opens a run row, runs the agent turn
   * under a lease heartbeat and a timeout, then records the result and re-arms
   * (or disables) the task.
   *
   * Several outcomes are handled distinctly. A broken schedule fails the run and,
   * after enough repeats, disables the task. A `catchup` run that is too late is
   * fast-forwarded instead of executed. A run that overruns the timeout is
   * aborted and treated as a failure. Only a clean success advances `nextRunAt`
   * by the schedule; any failure instead schedules a backoff retry.
   */
  private async executeScheduledTask(task: ScheduledTaskRow, trigger: ScheduledTaskTrigger): Promise<void> {
    // Manual runs have no scheduled fire time; stamp "now" so the run row and
    // event id still have a concrete instant to key off.
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
      // The schedule itself is unusable (e.g. a cron that never fires). Fail the
      // run, and once this has happened MAX_SCHEDULE_ERRORS times in a row, give
      // up and disable the task instead of retrying a schedule that cannot work.
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
    // Too-late catch-up: skip running the missed occurrence and just realign to
    // the next fire time, recording the run as `cancelled` (not `failed`) so it
    // does not count against the failure streak.
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
            // Read the aborted flag before cancelling the timer: a cancelled
            // timer can no longer report that it fired, so the order matters for
            // distinguishing a real timeout from a normal completion.
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
    // Stays null for a disabled task, which parks it (no further runs) until an
    // operator re-enables it.
    let nextRunAt: Date | null = null
    if (task.enabled) {
      if (status === 'succeeded') {
        try {
          // Compute the next fire from when the run finished, not from the
          // original scheduled time, so a long run does not immediately re-fire
          // for every boundary it overran.
          nextRunAt = computeNextRun({ schedule: task.schedule, after: finishedAt, taskId: task.id, timezone })
        } catch (caught) {
          // The run worked but the schedule can no longer produce a next time;
          // downgrade to a failure and apply the same disable-after-N policy as
          // the up-front schedule-error path.
          status = 'failed'
          error = `schedule error: ${errorMessage(caught)}`
          disableTask = task.consecutiveFailures + 1 >= MAX_SCHEDULE_ERRORS
          nextRunAt = disableTask ? null : new Date(finishedAt.getTime() + backoffMs(task.consecutiveFailures))
          logger.error({ error: caught, taskId: task.id, runId: run.id }, 'Scheduled task next-run calculation failed')
        }
      } else {
        // Failed or cancelled: retry on backoff rather than on the schedule.
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

  /**
   * Runs `fn` while periodically renewing the lease via `extend`, so a run that
   * outlasts the base lease duration keeps its claim instead of looking dead to
   * other instances.
   *
   * The heartbeat is best-effort: a failed renewal is logged but does not abort
   * the run here. If the lease truly lapses and a peer takes over, the fenced
   * `claimedBy` checks on the completion writes are what actually prevent this
   * instance from clobbering the new owner. The timer is `unref`ed so it cannot
   * keep the process alive, and is always cleared in `finally`.
   */
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

  /**
   * Sends an operator alert when a task has failed enough times in a row, but no
   * more than once per cooldown window.
   *
   * `task.consecutiveFailures` is the count *before* this run, so `+ 1` is the
   * streak including the failure just recorded. Both the threshold gate and the
   * cooldown gate must pass; the cooldown stops a task in a tight retry loop from
   * alerting on every attempt.
   */
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

  /**
   * Posts the failure-alert message to the task's delivery target via the outbox.
   *
   * Does nothing when the task has no delivery binding/room — there is nowhere to
   * tell anyone, so the alert is recorded but not sent. The error text is
   * truncated and run through redaction first so a noisy or sensitive failure
   * message cannot leak into a chat surface.
   */
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
        // Idempotency key for the outbox: keyed by task + alert timestamp so a
        // retry of this enqueue posts the same alert once, not twice.
        outboundKey: `scheduler-failure-alert:${task.id}:${now.toISOString()}`,
        providerRoomId,
        providerThreadId
      }
    })
    externalGatewayRuntime.triggerOutboxDrain(task.agentUid, bindingName)
  }
}

export const schedulerRuntime = new SchedulerRuntime()

// Assembles the execution context a scheduled run hands to the agent runtime.
// Uses a headless (no live chat surface) adapter, since scheduled work has no
// interactive session — output flows out through the outbox instead.
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

// Loads the agent and rejects when it is missing or no longer active, so a run
// never fires for a deactivated agent (the throw fails the run cleanly).
async function requireActiveAgent(agentUid: string): Promise<AgentResult> {
  const agent = await getAgent(agentUid)
  if (!agent || agent.principal.status !== 'active') throw new SchedulerRuntimeError(`agent not found: ${agentUid}`)
  return agent
}

// Builds the wake prompt for a checkback. Prefers the caller's saved wake
// message; when none was stored, falls back to a synthetic prompt. The fallback
// text deliberately frames the wakeup as a one-shot check and tells the agent to
// stay silent unless the user genuinely needs interrupting — without this the
// model tends to treat the wakeup as a recurring heartbeat and replay old tasks.
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

// Builds an abort signal that fires after `timeoutMs`, plus a `cancel` to clear
// it on normal completion. The timer is `unref`ed so a pending timeout never on
// its own holds the process open.
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

// Derives the idempotency key passed to the agent turn. A scheduled occurrence
// keys on task + fire time, so a retry of the *same* occurrence is deduplicated
// rather than producing a second turn. A manual run instead keys on its unique
// run id, so each operator "run now" is intentionally its own distinct event.
function scheduledTaskEventId(
  taskId: string,
  scheduledFor: Date,
  trigger: ScheduledTaskTrigger,
  runId: string
): string {
  return trigger === 'manual' ? runId : `${taskId}:${scheduledFor.toISOString()}`
}

// Maps an agent turn outcome onto a scheduler run status. A `fenced` turn (its
// lease was taken over) is treated like a cancellation, not a failure, so it
// does not count against the task's failure streak.
function resultStatus(status: AiAgentProgrammaticTurnResult['status']): Exclude<SchedulerRunStatus, 'running'> {
  return match(status)
    .with('succeeded', () => 'succeeded' as const)
    .with('cancelled', 'fenced', () => 'cancelled' as const)
    .otherwise(() => 'failed' as const)
}

// Looks up the retry delay for a given failure count, clamping at the last (and
// longest) backoff entry so repeated failures keep retrying at that ceiling.
function backoffMs(consecutiveFailures: number): number {
  return FAILURE_BACKOFF_MS[Math.min(consecutiveFailures, FAILURE_BACKOFF_MS.length - 1)]!
}

/**
 * Decides whether an overdue cron occurrence found at startup should be skipped
 * rather than run.
 *
 * Only applies to `catchup` runs of `cron` schedules: after downtime a cron task
 * may be hours late, and firing the stale occurrence is usually worse than
 * simply realigning to the next one. The grace window is half the schedule's
 * period (clamped between 2 minutes and 2 hours): a task is "stale" only once it
 * is late by more than that, which tolerates a brief restart but skips a deep
 * backlog. `every` schedules are intentionally excluded — their anchor math
 * already lands them on the next grid point — and so are manual/scheduled
 * triggers, which are never catch-up.
 *
 * @returns The fast-forward target and diagnostic numbers when the occurrence is
 *   too stale to run; otherwise undefined, meaning "go ahead and run it".
 */
function staleCronCatchup(input: {
  now: Date
  scheduledFor: Date
  task: ScheduledTaskRow
  timezone: string
  trigger: ScheduledTaskTrigger
}): { graceMs: number; latenessMs: number; nextRunAt: Date; reason: string } | undefined {
  if (input.trigger !== 'catchup' || input.task.schedule.kind !== 'cron') return undefined
  // Derive the schedule period from the gap to the occurrence after this one,
  // so the grace scales with cadence (a minutely task and a daily task get
  // proportionate, not identical, tolerances).
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
