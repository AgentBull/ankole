import { z } from 'zod'
import type { AgentTool } from '../../core'
import { modelIntegerIDFromWire } from '../../core/model-integer-id'
import { jsonToolResult } from '../../core/tool-result'
import type { TurnStart } from '../../lanes/actor_lane'
import { rpcMethods, type RPCRequester, type RPCRequestInit } from '../../lanes/rpc_lane'

const ListBackgroundJobsParamsSchema = z
  .object({
    status: z
      .enum(['live', 'stop'])
      .describe(
        'Job group. live includes queued, running, and waiting_on_user. stop includes succeeded, failed, or stopped jobs.'
      )
      .optional(),
    page: z
      .string()
      .regex(/^page_[1-9]\d*$/)
      .describe('Turn-local page reference returned by the preceding call.')
      .optional()
  })
  .strict()

const BackgroundAgentJobStatusSchema = z.enum([
  'queued',
  'running',
  'waiting_on_user',
  'succeeded',
  'failed',
  'stopped'
])

type ListBackgroundJobsResult = {
  jobs: Array<{
    job_id: number
    title: string
    status: z.output<typeof BackgroundAgentJobStatusSchema>
  }>
  next_page: string | null
}

export type ListBackgroundJobsToolOptions = {
  turnStart: TurnStart
  rpc: RPCRequester
}

export function createListBackgroundJobsTool(
  opts: ListBackgroundJobsToolOptions
): AgentTool<typeof ListBackgroundJobsParamsSchema, ListBackgroundJobsResult> {
  const cursors = new Map<string, string>()

  return {
    name: 'list_background_jobs',
    description: [
      'List BackgroundAgentJobs visible from the current conversation or channel.',
      'status defaults to live. live includes queued, running, and waiting_on_user. stop includes succeeded, failed, and stopped.',
      'Each page contains at most 32 Jobs, with the most recently updated Job first. Use next_page to continue.'
    ].join(' '),
    schema: ListBackgroundJobsParamsSchema,
    executionMode: 'parallel',
    isReadOnly: true,
    isDestructive: false,
    describeActivity: () => 'list background agent jobs',
    async execute(_toolCallID, params) {
      const request: RPCRequestInit<'background_agent_job.list'> = {
        status: params.status ?? 'live',
        cursor: params.page ? cursorForPage(cursors, params.page) : ''
      }
      const response = await opts.rpc(rpcMethods.backgroundAgentJobList, request, { turn: opts.turnStart.turn })
      return jsonToolResult({
        jobs: response.jobs.map(job => ({
          job_id: modelIntegerIDFromWire(job.jobId, 'background Agent Job id'),
          title: job.title,
          status: BackgroundAgentJobStatusSchema.parse(job.status)
        })),
        next_page: response.nextCursor ? registerPage(cursors, response.nextCursor) : null
      })
    }
  }
}

function cursorForPage(cursors: Map<string, string>, page: string): string {
  const cursor = cursors.get(page)
  if (!cursor) throw new Error(`unknown background Agent Job page ${page}; use next_page from this turn`)
  return cursor
}

function registerPage(cursors: Map<string, string>, cursor: string): string {
  for (const [page, existingCursor] of cursors) {
    if (existingCursor === cursor) return page
  }

  const page = `page_${cursors.size + 1}`
  cursors.set(page, cursor)
  return page
}
