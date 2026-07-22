import { z } from 'zod'
import type { AgentTool } from '../../core'
import { ModelIntegerID, modelIntegerIDFromWire, modelIntegerIDToWire } from '../../core/model-integer-id'
import { jsonToolResult } from '../../core/tool-result'
import { jsonObjectFromBytes } from '../../fabric/envelope_proto'
import type { TurnStart } from '../../lanes/actor_lane'
import { rpcMethods, type RPCRequester, type RPCRequestInit } from '../../lanes/rpc_lane'
import { modelVisibleTrajectory } from './model-trajectory'

const ShowBackgroundJobDetailsParamsSchema = z
  .object({
    job_id: ModelIntegerID.describe('BackgroundAgentJob id.')
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

const RecentTrajectorySchema = z.object({
  format: z.literal('ankole_chatml'),
  version: z.literal(1),
  messages: z.array(z.record(z.string(), z.unknown()))
})

const ExecutionSchema = z.object({
  attempt: z.number().int().nonnegative(),
  trajectory_page: RecentTrajectorySchema
})

type ShowBackgroundJobDetailsResult = {
  title: string
  status: z.output<typeof BackgroundAgentJobStatusSchema>
  continued_from_job_id: number | null
  workspace_owner_job_id: number
  attempts: number
  current_attempt: number
  error: ModelVisibleJobError | null
  attempt_history: Array<{
    attempt: number
    turn_statuses: string[]
    summary: string
  }>
  recent_trajectory: z.output<typeof RecentTrajectorySchema>
}

export type ShowBackgroundJobDetailsToolOptions = {
  turnStart: TurnStart
  rpc: RPCRequester
}

export function createShowBackgroundJobDetailsTool(
  opts: ShowBackgroundJobDetailsToolOptions
): AgentTool<typeof ShowBackgroundJobDetailsParamsSchema, ShowBackgroundJobDetailsResult> {
  return {
    name: 'show_background_job_details',
    description:
      'Show one BackgroundAgentJob. Returns its title, concrete status, continuation and workspace ownership, attempts, prior attempt history, current error, and an ankole_chatml trajectory built from its latest three stored semantic trajectory groups.',
    schema: ShowBackgroundJobDetailsParamsSchema,
    executionMode: 'parallel',
    isReadOnly: true,
    isDestructive: false,
    describeActivity: () => 'show background agent job details',
    async execute(_toolCallID, params) {
      const request: RPCRequestInit<'background_agent_job.get'> = {
        jobId: modelIntegerIDToWire(params.job_id),
        trajectoryLimit: 3,
        trajectoryCursor: ''
      }
      const response = await opts.rpc(rpcMethods.backgroundAgentJobGet, request, { turn: opts.turnStart.turn })
      const execution = ExecutionSchema.parse(
        jsonObjectFromBytes(response.executionJson, 'background_agent_job.execution_json')
      )
      const error = jsonObjectFromBytes(response.errorJson, 'background_agent_job.error_json')

      return jsonToolResult({
        title: response.title,
        status: BackgroundAgentJobStatusSchema.parse(response.status),
        continued_from_job_id: response.continuedFromJobId
          ? modelIntegerIDFromWire(response.continuedFromJobId, 'background_agent_job.continued_from_job_id')
          : null,
        workspace_owner_job_id: modelIntegerIDFromWire(
          response.workspaceOwnerJobId,
          'background_agent_job.workspace_owner_job_id'
        ),
        attempts: response.attempts,
        current_attempt: execution.attempt,
        error: modelVisibleJobError(error),
        attempt_history: response.attemptHistory.map(entry => ({
          attempt: entry.attempt,
          turn_statuses: entry.turnStatuses,
          summary: entry.summary
        })),
        recent_trajectory: modelVisibleTrajectory(execution.trajectory_page)
      })
    }
  }
}

type ModelVisibleJobError = {
  code?: string
  summary?: string
  retryable?: boolean
  codex_turn_status?: string
}

function modelVisibleJobError(error: Record<string, unknown> | null | undefined): ModelVisibleJobError | null {
  if (!error) return null

  const projected: ModelVisibleJobError = {
    ...(typeof error.code === 'string' ? { code: removeInternalUUIDs(error.code) } : {}),
    ...(typeof error.summary === 'string' ? { summary: removeInternalUUIDs(error.summary) } : {}),
    ...(typeof error.retryable === 'boolean' ? { retryable: error.retryable } : {}),
    ...(typeof error.codex_turn_status === 'string' ? { codex_turn_status: error.codex_turn_status } : {})
  }
  return Object.keys(projected).length > 0 ? projected : null
}

function removeInternalUUIDs(value: string): string {
  return value.replace(/\b[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\b/gi, '[internal-id]')
}
