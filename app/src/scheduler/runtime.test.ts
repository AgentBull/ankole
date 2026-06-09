import 'reflect-metadata'
import { afterEach, describe, expect, it } from 'bun:test'
import { eq, like } from 'drizzle-orm'
import { loadTestEnvFiles } from '@/common/tests/load-test-env'

await loadTestEnvFiles()

const { DB } = await import('@/common/database')
const { AiAgentConversations, AiAgentMessages, Principals, ScheduledTaskRuns, ScheduledTasks } =
  await import('@/common/db-schema')
const { aiAgentConversationService, textContent } = await import('@/ai-agent/conversation-service')
const { createAgent } = await import('@/principals/agents/service')
const { SchedulerRuntime } = await import('./runtime')
const { schedulerStore } = await import('./store')

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
