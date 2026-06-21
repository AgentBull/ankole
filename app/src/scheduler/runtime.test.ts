// Integration tests for SchedulerRuntime against a real database. They cover the
// behaviors that are hard to reason about by reading the code: startup catch-up,
// lease-scoped orphan recovery (a live peer's run must survive), mid-run lease
// renewal, the failure-alert threshold plus cooldown, and the run timeout.
import { afterEach, describe, expect, it } from 'bun:test'
import { eq, like } from 'drizzle-orm'
import { loadTestEnvFiles } from '@/common/tests/load-test-env'

// Modules are imported dynamically after env files load, so DB connection
// settings from the test env are in place before any module reads them.
await loadTestEnvFiles()

const { DB } = await import('@/common/database')
const { AiAgentConversations, AiAgentMessages, Principals, ScheduledTaskRuns, ScheduledTasks } =
  await import('@/common/db-schema')
const { aiAgentConversationService, textContent } = await import('@/ai-agent/conversation-service')
const { createAgent } = await import('@/principals/agents/service')
const { SchedulerRuntime } = await import('./runtime')
const { schedulerStore } = await import('./store')

// Unique per test run; every row this file creates is keyed by it so cleanup can
// delete exactly this run's rows without disturbing anything else in the database.
const testPrefix = `test_scheduler_${Date.now()}_${Math.random().toString(36).slice(2)}`.toLowerCase()

interface ProgrammaticTurnStub {
  conversationProviderRoomId: string
  eventId: string
  eventSource: string
  message: string
  signal?: AbortSignal
}

interface AgentExecutionContextStub {
  agentUid: string
  bindingName: string
}

afterEach(async () => {
  await clearTestRows()
})

describe('SchedulerRuntime', () => {
  it('records startup due scheduled tasks as catchup runs', async () => {
    const agentUid = uid('catchup_agent')
    await createAgent({ uid: agentUid })
    const task = await createDueTask(agentUid, 'catchup_task')
    const runtime = new SchedulerRuntime()
    runtime.setAgentExecutor(fakeProgrammaticExecutor())

    try {
      await runtime.start()
      await eventually(async () => expect(await runsForTask(task.id)).toHaveLength(1))
    } finally {
      await runtime.stop()
    }

    const [run] = await runsForTask(task.id)
    expect(run?.trigger).toBe('catchup')
    expect(run?.status).toBe('succeeded')

    const refreshed = await taskById(task.id)
    expect(refreshed?.claimedBy).toBeNull()
    expect(refreshed?.leaseExpiresAt).toBeNull()
    expect(refreshed?.nextRunAt?.getTime()).toBeGreaterThan(Date.now() - 5_000)
  })

  it('recovers only orphaned runs whose lease lapsed, never a live peer instance run', async () => {
    const agentUid = uid('recover_scope_agent')
    await createAgent({ uid: agentUid })

    // A peer instance is mid-run with a fresh lease: recovery must leave it alone,
    // or a rolling deploy would kill a healthy run and double-deliver.
    const liveTask = await createDueTask(agentUid, 'recover_live')
    const liveRun = await schedulerStore.createTaskRun({
      instanceId: 'peer-alive',
      scheduledFor: new Date(),
      task: liveTask,
      trigger: 'schedule'
    })
    await DB.update(ScheduledTasks)
      .set({ claimedBy: 'peer-alive', leaseExpiresAt: new Date(Date.now() + 5 * 60_000) })
      .where(eq(ScheduledTasks.id, liveTask.id))

    // The instance running this one died: its lease has lapsed, so it is a genuine orphan.
    const deadTask = await createDueTask(agentUid, 'recover_dead')
    const deadRun = await schedulerStore.createTaskRun({
      instanceId: 'peer-dead',
      scheduledFor: new Date(),
      task: deadTask,
      trigger: 'schedule'
    })
    await DB.update(ScheduledTasks)
      .set({ claimedBy: 'peer-dead', leaseExpiresAt: new Date(Date.now() - 60_000) })
      .where(eq(ScheduledTasks.id, deadTask.id))

    const now = new Date()
    const recovered = await schedulerStore.recoverOrphanedTaskRuns({
      error: 'test orphan recovery',
      now,
      retryAt: new Date(now.getTime() + 30_000)
    })
    expect(recovered).toBe(1)

    expect((await runsForTask(liveTask.id)).find(run => run.id === liveRun.id)?.status).toBe('running')
    expect((await runsForTask(deadTask.id)).find(run => run.id === deadRun.id)?.status).toBe('failed')
  })

  it('renews the task lease while a scheduled turn is still running', async () => {
    const agentUid = uid('lease_agent')
    await createAgent({ uid: agentUid })
    const task = await createDueTask(agentUid, 'lease_task')
    let observedClaimedAt: Date | null = null
    let observedLeaseExpiresAt: Date | null = null
    const runtime = new SchedulerRuntime()
    runtime.setRuntimeTuningForTest({ leaseMs: 100, leaseHeartbeatMs: 10 })
    runtime.setAgentExecutor(
      fakeProgrammaticExecutor({
        beforeReturn: async () => {
          await Bun.sleep(45)
          const row = await taskById(task.id)
          observedClaimedAt = row?.claimedAt ?? null
          observedLeaseExpiresAt = row?.leaseExpiresAt ?? null
        }
      })
    )

    await runtime.runNow(task.id)

    expect(observedClaimedAt).toBeInstanceOf(Date)
    expect(observedLeaseExpiresAt).toBeInstanceOf(Date)
    // With a 100ms lease, an un-renewed lease would expire at claimedAt + 100.
    // Observing an expiry beyond that proves the heartbeat extended it mid-run.
    expect(observedLeaseExpiresAt!.getTime()).toBeGreaterThan(observedClaimedAt!.getTime() + 100)
  })

  it('records failure alerts only after the threshold and respects cooldown', async () => {
    const agentUid = uid('failure_agent')
    await createAgent({ uid: agentUid })
    const task = await createDueTask(agentUid, 'failure_task')
    await DB.update(ScheduledTasks).set({ consecutiveFailures: 2 }).where(eq(ScheduledTasks.id, task.id))

    const runtime = new SchedulerRuntime()
    runtime.setRuntimeTuningForTest({ failureAlertCooldownMs: 60_000, failureAlertThreshold: 3 })
    runtime.setAgentExecutor(failingProgrammaticExecutor())

    await runtime.runNow(task.id)

    const afterFirstFailure = await taskById(task.id)
    expect(afterFirstFailure?.lastStatus).toBe('failed')
    expect(afterFirstFailure?.consecutiveFailures).toBe(3)
    expect(afterFirstFailure?.lastAlertAt).toBeInstanceOf(Date)

    const firstAlertAt = afterFirstFailure!.lastAlertAt!
    await runtime.runNow(task.id)

    const afterSecondFailure = await taskById(task.id)
    expect(afterSecondFailure?.consecutiveFailures).toBe(4)
    expect(afterSecondFailure?.lastAlertAt?.getTime()).toBe(firstAlertAt.getTime())

    const runs = await runsForTask(task.id)
    expect(runs.map(run => run.status)).toEqual(['failed', 'failed'])
    expect(runs.every(run => run.error?.includes('planned scheduler failure'))).toBe(true)
  })

  it('aborts scheduled task runs that exceed the runtime timeout', async () => {
    const agentUid = uid('timeout_agent')
    await createAgent({ uid: agentUid })
    const task = await createDueTask(agentUid, 'timeout_task')
    const runtime = new SchedulerRuntime()
    runtime.setRuntimeTuningForTest({ taskRunTimeoutMs: 20 })
    runtime.setAgentExecutor({
      async runProgrammaticTurn(context: AgentExecutionContextStub, turn: ProgrammaticTurnStub) {
        await new Promise<void>(resolve => turn.signal?.addEventListener('abort', () => resolve(), { once: true }))
        const conversation = await aiAgentConversationService.getOrCreateActiveConversation({
          agentUid: context.agentUid,
          bindingName: context.bindingName,
          providerRoomId: turn.conversationProviderRoomId
        })
        const message = await aiAgentConversationService.appendMessage({
          conversationId: conversation.id,
          role: 'user',
          content: textContent(turn.message),
          eventSource: turn.eventSource,
          eventId: turn.eventId
        })
        return {
          conversationId: conversation.id,
          enqueuedOutput: false,
          status: 'cancelled' as const,
          triggerMessageId: message.id
        }
      }
    })

    await runtime.runNow(task.id)

    const [run] = await runsForTask(task.id)
    expect(run?.status).toBe('failed')
    expect(run?.error).toContain('scheduled task timed out')
    expect((run?.metadata as { timed_out?: unknown } | undefined)?.timed_out).toBe(true)
    const refreshed = await taskById(task.id)
    expect(refreshed?.claimedBy).toBeNull()
    expect(refreshed?.leaseExpiresAt).toBeNull()
  })
})

// Creates a task that is already due (nextRunAt in the past) so a tick or runNow
// picks it up immediately, without waiting for a real schedule boundary.
async function createDueTask(agentUid: string, name: string) {
  return schedulerStore.createTask({
    agentUid,
    delivery: null,
    enabled: true,
    name,
    nextRunAt: new Date(Date.now() - 60_000),
    payload: { message: `run ${name}` },
    schedule: {
      anchor_ms: Date.now() - 120_000,
      every_ms: 60_000,
      kind: 'every'
    }
  })
}

function fakeProgrammaticExecutor(input: { beforeReturn?: () => Promise<void> } = {}) {
  return {
    async runProgrammaticTurn(context: AgentExecutionContextStub, turn: ProgrammaticTurnStub) {
      await input.beforeReturn?.()
      const conversation = await aiAgentConversationService.getOrCreateActiveConversation({
        agentUid: context.agentUid,
        bindingName: context.bindingName,
        providerRoomId: turn.conversationProviderRoomId
      })
      const message = await aiAgentConversationService.appendMessage({
        conversationId: conversation.id,
        role: 'user',
        content: textContent(turn.message),
        eventSource: turn.eventSource,
        eventId: turn.eventId
      })
      return {
        conversationId: conversation.id,
        enqueuedOutput: false,
        status: 'succeeded' as const,
        triggerMessageId: message.id
      }
    }
  }
}

function failingProgrammaticExecutor() {
  return {
    async runProgrammaticTurn() {
      throw new Error('planned scheduler failure')
    }
  }
}

async function taskById(taskId: string): Promise<typeof ScheduledTasks.$inferSelect | undefined> {
  const [task] = await DB.select().from(ScheduledTasks).where(eq(ScheduledTasks.id, taskId)).limit(1)
  return task
}

async function runsForTask(taskId: string): Promise<Array<typeof ScheduledTaskRuns.$inferSelect>> {
  return DB.select().from(ScheduledTaskRuns).where(eq(ScheduledTaskRuns.taskId, taskId))
}

// Retries an assertion until it passes or the deadline elapses. Used where the
// scheduler tick runs in the background, so the row under test appears only after
// some asynchronous delay rather than synchronously.
async function eventually(assertion: () => Promise<void>, timeoutMs = 2_000): Promise<void> {
  const deadline = Date.now() + timeoutMs
  let lastError: unknown
  while (Date.now() < deadline) {
    try {
      await assertion()
      return
    } catch (error) {
      lastError = error
      await Bun.sleep(25)
    }
  }
  if (lastError) throw lastError
}

async function clearTestRows(): Promise<void> {
  await DB.delete(AiAgentMessages).where(like(AiAgentMessages.agentUid, `${testPrefix}%`))
  await DB.delete(AiAgentConversations).where(like(AiAgentConversations.agentUid, `${testPrefix}%`))
  await DB.delete(ScheduledTaskRuns).where(like(ScheduledTaskRuns.agentUid, `${testPrefix}%`))
  await DB.delete(ScheduledTasks).where(like(ScheduledTasks.agentUid, `${testPrefix}%`))
  await DB.delete(Principals).where(like(Principals.uid, `${testPrefix}%`))
}

function uid(suffix: string): string {
  return `${testPrefix}_${suffix}`
}
