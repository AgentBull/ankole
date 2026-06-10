import { z } from 'zod'
import { DomainError } from '@/common/errors'
import { genUUIDv7 } from '@agentbull/bullx-native-addons'
import { type ScheduledTaskDelivery, type ScheduledTaskPayload, type ScheduledTaskSchedule } from '@/common/db-schema'
import { loadSystemTimezone } from '@/config/system'
import { getAgent } from '@/principals/agents/service'
import { computeNextRun, ScheduledTaskScheduleSchema, validateCronExpression } from './schedule'
import { schedulerRuntime } from './runtime'
import { schedulerStore, type SchedulerStore } from './store'

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

export class SchedulerService {
  constructor(private readonly store: SchedulerStore = schedulerStore) {}

  async listAgentTasks(agentUid: string) {
    await requireAgent(agentUid)
    return this.store.listTasks(agentUid)
  }

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

  async getTask(taskId: string) {
    const task = await this.store.getTask(taskId)
    if (!task) throw new DomainError(404, `Unknown scheduled task: ${taskId}`)
    return {
      task,
      runs: await this.store.listRuns(taskId, 20)
    }
  }

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

  async runNow(taskId: string): Promise<void> {
    const existing = await this.store.getTask(taskId)
    if (!existing) throw new DomainError(404, `Unknown scheduled task: ${taskId}`)
    await schedulerRuntime.runNow(taskId)
  }

  private async nextRun(schedule: ScheduledTaskSchedule, taskId: string): Promise<Date> {
    return computeNextRun({
      schedule,
      after: new Date(),
      taskId,
      timezone: await loadSystemTimezone()
    })
  }
}

function normalizeDelivery(delivery: z.output<typeof ScheduledTaskDeliverySchema>): ScheduledTaskDelivery {
  return {
    binding_name: delivery.binding_name,
    room_id: delivery.room_id,
    thread_id: delivery.thread_id ?? null
  }
}

export const schedulerService = new SchedulerService()

function validateSchedule(schedule: ScheduledTaskSchedule): void {
  if (schedule.kind === 'cron') validateCronExpression(schedule.expression)
}

async function requireAgent(agentUid: string): Promise<void> {
  const agent = await getAgent(agentUid)
  if (!agent || agent.principal.status !== 'active') {
    throw new DomainError(404, `Unknown active agent: ${agentUid}`)
  }
}
