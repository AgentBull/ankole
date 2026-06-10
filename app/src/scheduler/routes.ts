import { Elysia } from 'elysia'
import { z } from 'zod'
import { DomainError, statusFromError } from '@/common/errors'
import { logger } from '@/common/logger'
import { AppEnv } from '@/config/env'
import { requireConsoleAdmin } from '@/console/routes'
import { CreateScheduledTaskSchema, UpdateScheduledTaskSchema, schedulerService } from './service'

const taskIdParams = z.object({ taskId: z.string().min(1) })
const agentParams = z.object({ uid: z.string().min(1) })

export function schedulerRoutes() {
  return new Elysia({ name: 'scheduler-routes' })
    .onError(({ code, error, set }) => {
      if (error instanceof DomainError) {
        set.status = error.status
        return { error: error.message }
      }
      const status = statusFromError(error)
      const isInternalServerError = status >= 500
      isInternalServerError
        ? logger.error({ error, code }, 'Scheduler API Error')
        : logger.warn({ error, code }, 'Scheduler API Error')
      set.status = status
      return {
        error: {
          code: status,
          status: String(code),
          message:
            AppEnv.IS_PRODUCTION && isInternalServerError
              ? 'Internal Server Error'
              : error instanceof Error
                ? error.message
                : String(error)
        }
      }
    })
    .get(
      '/api/console/agents/:uid/scheduled-tasks',
      async ({ params, request }) => {
        await requireConsoleAdmin(request)
        return { tasks: await schedulerService.listAgentTasks(params.uid) }
      },
      { params: agentParams }
    )
    .post(
      '/api/console/agents/:uid/scheduled-tasks',
      async ({ params, body, request, set }) => {
        await requireConsoleAdmin(request)
        set.status = 201
        return { task: await schedulerService.createTask(params.uid, body) }
      },
      { params: agentParams, body: CreateScheduledTaskSchema }
    )
    .get(
      '/api/console/scheduled-tasks/:taskId',
      async ({ params, request }) => {
        await requireConsoleAdmin(request)
        return await schedulerService.getTask(params.taskId)
      },
      { params: taskIdParams }
    )
    .put(
      '/api/console/scheduled-tasks/:taskId',
      async ({ params, body, request }) => {
        await requireConsoleAdmin(request)
        return { task: await schedulerService.updateTask(params.taskId, body) }
      },
      { params: taskIdParams, body: UpdateScheduledTaskSchema }
    )
    .delete(
      '/api/console/scheduled-tasks/:taskId',
      async ({ params, request, set }) => {
        await requireConsoleAdmin(request)
        await schedulerService.deleteTask(params.taskId)
        set.status = 204
      },
      { params: taskIdParams }
    )
    .post(
      '/api/console/scheduled-tasks/:taskId/run',
      async ({ params, request, set }) => {
        await requireConsoleAdmin(request)
        await schedulerService.runNow(params.taskId)
        set.status = 202
        return { status: 'accepted' }
      },
      { params: taskIdParams }
    )
    .get(
      '/api/console/scheduled-tasks/:taskId/runs',
      async ({ params, request }) => {
        await requireConsoleAdmin(request)
        return { runs: await schedulerService.listRuns(params.taskId) }
      },
      { params: taskIdParams }
    )
}
