import { z } from 'zod'
import type { AgentTool } from '../../core'
import { ModelIntegerID, modelIntegerIDFromWire, modelIntegerIDToWire } from '../../core/model-integer-id'
import { jsonToolResult } from '../../core/tool-result'
import { jsonObjectFromBytes } from '../../fabric/envelope_proto'
import type { TurnStart } from '../../lanes/actor_lane'
import { rpcMethods, type RPCRequester, type RPCRequestInit } from '../../lanes/rpc_lane'
import {
  BackgroundAgentJobTrajectorySchema,
  modelVisibleTrajectory,
  type BackgroundAgentJobTrajectory
} from './model-trajectory'
import { BackgroundAgentJobStatusSchema, type BackgroundAgentJobStatus } from './status'

const ShowBackgroundJobDetailsParamsSchema = z
  .object({
    job_id: ModelIntegerID.describe('Background agent job id.')
  })
  .strict()

const NonNegativeIntegerSchema = z.number().int().nonnegative()

const ExecutionProgressSchema = z.object({
  completed_items: NonNegativeIntegerSchema,
  tool_calls: NonNegativeIntegerSchema,
  tools_used: z.array(
    z.object({
      name: z.string(),
      calls: NonNegativeIntegerSchema
    })
  ),
  files_changed: z.array(z.string()),
  skills_used: z.array(z.string()).optional(),
  active_items: z.array(
    z.object({
      scope: z.enum(['lead', 'child']),
      name: z.string()
    })
  ),
  plan: z.record(z.string(), z.unknown()).optional()
})

const UsageBreakdownSchema = z.object({
  total_tokens: NonNegativeIntegerSchema,
  input_tokens: NonNegativeIntegerSchema,
  cached_input_tokens: NonNegativeIntegerSchema,
  output_tokens: NonNegativeIntegerSchema,
  reasoning_output_tokens: NonNegativeIntegerSchema
})

const ExecutionUsageSchema = z.object({
  thread_total: UsageBreakdownSchema,
  last_model_call: UsageBreakdownSchema,
  model_context_window: NonNegativeIntegerSchema.optional()
})

const ExecutionSchema = z.object({
  attempt: NonNegativeIntegerSchema,
  current: z
    .object({
      runtime_turn_id: z.string(),
      kind: z.string(),
      status: z.enum(['in_progress', 'completed', 'failed', 'interrupted'])
    })
    .optional(),
  threads: z.object({
    total: NonNegativeIntegerSchema,
    child: NonNegativeIntegerSchema
  }),
  turns: z.object({
    lead: NonNegativeIntegerSchema,
    child: NonNegativeIntegerSchema,
    compaction: NonNegativeIntegerSchema,
    active: NonNegativeIntegerSchema
  }),
  progress: ExecutionProgressSchema,
  usage: ExecutionUsageSchema.optional(),
  trajectory_page: BackgroundAgentJobTrajectorySchema,
  updated_at: z.string()
})

type ShowBackgroundJobDetailsResult = {
  title: string
  status: BackgroundAgentJobStatus
  continued_from_job_id: number | null
  workspace_owner_job_id: number
  attempts: number
  current_attempt: number
  current_turn_status: 'in_progress' | 'completed' | 'failed' | 'interrupted' | null
  threads: z.infer<typeof ExecutionSchema>['threads']
  turns: Pick<z.infer<typeof ExecutionSchema>['turns'], 'lead' | 'child' | 'active'>
  progress: z.infer<typeof ExecutionProgressSchema>
  usage: z.infer<typeof ExecutionUsageSchema> | null
  updated_at: string
  error: ModelVisibleJobError | null
  attempt_history: Array<{
    attempt: number
    turn_statuses: string[]
    summary: string
  }>
  recent_trajectory: BackgroundAgentJobTrajectory
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
    description: 'Show job details: status, current progress, usage, attempt history, and the latest trajectory page.',
    schema: ShowBackgroundJobDetailsParamsSchema,
    executionMode: 'parallel',
    isReadOnly: true,
    isDestructive: false,
    describeActivity: () => ({ key: 'signals_gateway.reply.activity.background_job_show' }),
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
        current_turn_status: execution.current?.status ?? null,
        threads: execution.threads,
        turns: {
          lead: execution.turns.lead,
          child: execution.turns.child,
          active: execution.turns.active
        },
        progress: execution.progress,
        usage: execution.usage ?? null,
        updated_at: execution.updated_at,
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
