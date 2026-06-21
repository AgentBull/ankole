import { Elysia } from 'elysia'
import { z } from 'zod'
import { DomainError, statusFromError } from '@/common/errors'
import { logger } from '@/common/logger'
import { AppEnv } from '@/config/env'
import { requireConsoleAdmin } from '@/console/routes'
import { CreateScheduledTaskSchema, UpdateScheduledTaskSchema, schedulerService } from './service'

const taskIdParams = z.object({ taskId: z.string().min(1) })
const agentParams = z.object({ uid: z.string().min(1) })

/**
 * Console-admin HTTP surface for scheduled tasks (list, create, read, update,
 * delete, run-now, list-runs). Every route is gated by {@link requireConsoleAdmin}
 * and delegates to {@link schedulerService}; this layer only does auth, status
 * codes, and error shaping.
 */
export function schedulerRoutes() {
  return new Elysia({ name: 'scheduler-routes' })
    .onError(({ code, error, set }) => {
      // A DomainError already carries the intended HTTP status and a
      // caller-safe message, so it is surfaced verbatim and not logged as a
      // server fault.
      if (error instanceof DomainError) {
        set.status = error.status
        return { error: error.message }
      }
      const status = statusFromError(error)
      const isInternalServerError = status >= 500
      // Log 5xx as errors and 4xx as warnings, so genuine server faults stand
      // out from ordinary client mistakes.
      isInternalServerError
        ? logger.error({ error, code }, 'Scheduler API Error')
        : logger.warn({ error, code }, 'Scheduler API Error')
      set.status = status
      return {
        error: {
          code: status,
          status: String(code),
          // In production a 5xx body is reduced to a generic line so internal
          // error text does not leak to clients; non-prod and 4xx keep the real
          // message to aid debugging.
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
        // 202 Accepted: this kicks off the run but the agent turn completes
        // asynchronously, so the response does not wait for the result.
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
