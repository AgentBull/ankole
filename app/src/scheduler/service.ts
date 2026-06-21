import { z } from 'zod'
import { DomainError } from '@/common/errors'
import { genUUIDv7 } from '@agentbull/bullx-native-addons'
import { type ScheduledTaskDelivery, type ScheduledTaskPayload, type ScheduledTaskSchedule } from '@/common/db-schema'
import { loadSystemTimezone } from '@/config/system'
import { getAgent } from '@/principals/agents/service'
import { computeNextRun, ScheduledTaskScheduleSchema, validateCronExpression } from './schedule'
import { schedulerRuntime } from './runtime'
import { schedulerStore, type SchedulerStore } from './store'

// Validates the task payload. `message` is required; `catchall` keeps any extra
// caller-supplied JSON fields rather than stripping them, so a task can carry
// arbitrary structured context alongside the prompt.
export const ScheduledTaskPayloadSchema = z
  .object({
    message: z.string().min(1)
  })
  .catchall(z.json())

export const ScheduledTaskDeliverySchema = z
  .object({
    binding_name: z.string().min(1),
    room_id: z.string().min(1),
    thread_id: z.string().min(1).optional()
  })
  .strict()

export const CreateScheduledTaskSchema = z
  .object({
    name: z.string().min(1),
    enabled: z.boolean().optional(),
    schedule: ScheduledTaskScheduleSchema,
    payload: ScheduledTaskPayloadSchema,
    delivery: ScheduledTaskDeliverySchema.nullable().optional()
  })
  .strict()

export const UpdateScheduledTaskSchema = z
  .object({
    name: z.string().min(1).optional(),
    enabled: z.boolean().optional(),
    schedule: ScheduledTaskScheduleSchema.optional(),
    payload: ScheduledTaskPayloadSchema.optional(),
    delivery: ScheduledTaskDeliverySchema.nullable().optional()
  })
  .strict()

export type CreateScheduledTaskInput = z.output<typeof CreateScheduledTaskSchema>
export type UpdateScheduledTaskInput = z.output<typeof UpdateScheduledTaskSchema>

/**
 * Application-layer API for managing scheduled tasks. Validates input, resolves
 * the first fire time, and delegates persistence to the store. The HTTP routes
 * and any internal callers go through here rather than touching the store
 * directly, so the agent-exists check and schedule validation are enforced in
 * one place.
 */
export class SchedulerService {
  constructor(private readonly store: SchedulerStore = schedulerStore) {}

  /** Lists an agent's tasks after confirming the agent exists and is active. */
  async listAgentTasks(agentUid: string) {
    await requireAgent(agentUid)
    return this.store.listTasks(agentUid)
  }

  /**
   * Creates a task and arms it. `nextRunAt` is seeded only when the task starts
   * enabled; a task created disabled has no fire time until it is enabled.
   */
  async createTask(agentUid: string, input: CreateScheduledTaskInput) {
    await requireAgent(agentUid)
    validateSchedule(input.schedule)
    const enabled = input.enabled ?? true
    const taskId = genUUIDv7()
    return this.store.createTask({
      agentUid,
      delivery: input.delivery ? normalizeDelivery(input.delivery) : null,
      enabled,
      id: taskId,
      name: input.name,
      nextRunAt: enabled ? await this.nextRun(input.schedule, taskId) : null,
      payload: input.payload as ScheduledTaskPayload,
      schedule: input.schedule as ScheduledTaskSchedule
    })
  }

  /** Returns a task together with its most recent runs for a detail view. */
  async getTask(taskId: string) {
    const task = await this.store.getTask(taskId)
    if (!task) throw new DomainError(404, `Unknown scheduled task: ${taskId}`)
    return {
      task,
      runs: await this.store.listRuns(taskId, 20)
    }
  }

  /**
   * Applies a partial task update and recomputes the fire time only when it
   * could have changed.
   *
   * The `nextRunAt` decision has three cases: disabling clears it (the task
   * stops running); changing the schedule, or enabling a disabled task,
   * recomputes it from now; anything else leaves it as `undefined`, which the
   * store reads as "do not touch", so editing only the name or payload does not
   * disturb an already-scheduled fire time.
   */
  async updateTask(taskId: string, input: UpdateScheduledTaskInput) {
    const existing = await this.store.getTask(taskId)
    if (!existing) throw new DomainError(404, `Unknown scheduled task: ${taskId}`)
    const schedule = (input.schedule ?? existing.schedule) as ScheduledTaskSchedule
    validateSchedule(schedule)
    const scheduleChanged = input.schedule !== undefined
    const enabledChanged = input.enabled !== undefined && input.enabled !== existing.enabled
    const nextRunAt =
      input.enabled === false
        ? null
        : scheduleChanged || (enabledChanged && input.enabled === true)
          ? await this.nextRun(schedule, taskId)
          : undefined
    return this.store.updateTask({
      taskId,
      name: input.name,
      enabled: input.enabled,
      schedule: input.schedule as ScheduledTaskSchedule | undefined,
      payload: input.payload as ScheduledTaskPayload | undefined,
      delivery: 'delivery' in input ? (input.delivery ? normalizeDelivery(input.delivery) : null) : undefined,
      nextRunAt
    })
  }

  async deleteTask(taskId: string): Promise<void> {
    await this.store.deleteTask(taskId)
  }

  async listRuns(taskId: string) {
    return this.store.listRuns(taskId)
  }

  /**
   * Triggers an immediate run. Confirms the task exists for a clean 404, then
   * hands off to the runtime, which still claims the lease — so this returns
   * without error even if the runtime declines because a run is already active.
   */
  async runNow(taskId: string): Promise<void> {
    const existing = await this.store.getTask(taskId)
    if (!existing) throw new DomainError(404, `Unknown scheduled task: ${taskId}`)
    await schedulerRuntime.runNow(taskId)
  }

  // Resolves the first fire time for a schedule from now, in the installation timezone.
  private async nextRun(schedule: ScheduledTaskSchedule, taskId: string): Promise<Date> {
    return computeNextRun({
      schedule,
      after: new Date(),
      taskId,
      timezone: await loadSystemTimezone()
    })
  }
}

// Converts the parsed delivery (optional `thread_id`) into the stored shape,
// which uses an explicit null so the "no thread" case is uniform downstream.
function normalizeDelivery(delivery: z.output<typeof ScheduledTaskDeliverySchema>): ScheduledTaskDelivery {
  return {
    binding_name: delivery.binding_name,
    room_id: delivery.room_id,
    thread_id: delivery.thread_id ?? null
  }
}

export const schedulerService = new SchedulerService()

// Validates schedule semantics the zod schema cannot: only cron needs a parse
// check, since `every` schedules are fully constrained by the schema already.
function validateSchedule(schedule: ScheduledTaskSchedule): void {
  if (schedule.kind === 'cron') validateCronExpression(schedule.expression)
}

// Asserts the agent exists and is active, raising a 404 domain error otherwise
// so callers never create or list tasks against a missing or disabled agent.
async function requireAgent(agentUid: string): Promise<void> {
  const agent = await getAgent(agentUid)
  if (!agent || agent.principal.status !== 'active') {
    throw new DomainError(404, `Unknown active agent: ${agentUid}`)
  }
}
