import { z } from 'zod'
import { defineWorkerTool, type AgentToolResult, type WorkerAgentTool } from '../../core'
import { utf8ByteLength } from '../../common/text-sanitize'
import { ModelIntegerID, modelIntegerIDFromWire, modelIntegerIDToWire } from '../../core/model-integer-id'
import { jsonToolResult } from '../../core/tool-result'
import { fitToolResultTextWindow } from '../../core/tool-result-window'
import { nonNegativeSafeIntegerFromWire } from '../../core/wire-integer'
import { jsonObjectFromBytes } from '../../fabric/envelope_proto'
import {
  backgroundAgentJobPathHandoff,
  type BackgroundAgentJobPathHandoff
} from '../../core/background-agent-job-handoff'
import type { TurnStart } from '../../lanes/actor_lane'
import { rpcMethods, type RPCRequester, type RPCRequestInit } from '../../lanes/rpc_lane'
import { modelVisibleTrajectory } from './model-trajectory'
import {
  BackgroundAgentJobStatusSchema,
  BackgroundAgentJobTrajectorySchema,
  type BackgroundAgentJobStatus,
  type BackgroundAgentJobTrajectory
} from '../../core/background-agent-job-documents'

const ShowBackgroundJobDetailsParamsSchema = z
  .object({
    job_id: ModelIntegerID.describe('Background agent job id.'),
    result_offset: z
      .number()
      .int()
      .nonnegative()
      .max(Number.MAX_SAFE_INTEGER)
      .describe(
        'Stable UTF-8 byte offset into the persisted result. Use 0 for the first chunk; omit it to show execution details.'
      )
      .optional()
  })
  .strict()

const NonNegativeIntegerSchema = z.number().int().nonnegative()

const ExecutionProgressSchema = z.object({
  completed_items: NonNegativeIntegerSchema,
  tool_calls: NonNegativeIntegerSchema,
  tools_used: z.array(
    z.object({
      namespace: z.string().optional(),
      name: z.string(),
      calls: NonNegativeIntegerSchema
    })
  ),
  tool_execution_mechanisms: z
    .array(
      z.object({
        namespace: z.string().optional(),
        name: z.string(),
        execution_mechanism: z.enum(['provider_hosted', 'local_dynamic']),
        calls: NonNegativeIntegerSchema
      })
    )
    .default([]),
  files_changed: z.array(z.string()),
  skills_used: z.array(z.string()).optional(),
  active_items: z.array(
    z.object({
      scope: z.enum(['lead', 'child']),
      namespace: z.string().optional(),
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

type ResultRef = {
  type: 'background_agent_job'
  job_id: number
}

type ShowBackgroundJobExecutionDetails = {
  title: string
  status: BackgroundAgentJobStatus
  result_ref: ResultRef | null
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

type ShowBackgroundJobResultChunk = {
  title: string
  status: 'succeeded'
  result_ref: ResultRef
  workspace_owner_job_id: number
  project_path: string | null
  artifacts: BackgroundAgentJobPathHandoff | null
  artifact_roots: BackgroundAgentJobPathHandoff | null
  result: {
    offset: number
    output_text: string
    next_offset: number | null
  }
}

type ResultPaths = Pick<ShowBackgroundJobResultChunk, 'project_path' | 'artifacts' | 'artifact_roots'>

type ShowBackgroundJobDetailsResult = ShowBackgroundJobExecutionDetails | ShowBackgroundJobResultChunk

export type ShowBackgroundJobDetailsToolOptions = {
  turnStart: TurnStart
  rpc: RPCRequester
}

export function createShowBackgroundJobDetailsTool(
  opts: ShowBackgroundJobDetailsToolOptions
): WorkerAgentTool<typeof ShowBackgroundJobDetailsParamsSchema, ShowBackgroundJobDetailsResult> {
  return defineWorkerTool({
    name: 'show_background_job_details',
    description: [
      'Show job status, progress, tool execution mechanisms, usage, attempt history, and the latest trajectory page.',
      'For an exact persisted result from a succeeded job, set result_offset to 0, concatenate result.output_text, and pass result.next_offset to the next call until it is null.',
      'Each result chunk also carries the real Job Workspace (project_path, owned by workspace_owner_job_id) and absolute artifact paths; use those paths to read or copy the files instead of guessing a directory from the job id or a relative path in the text.',
      'Result offsets are stable and can be resumed in a later turn.'
    ].join(' '),
    schema: ShowBackgroundJobDetailsParamsSchema,
    executionMode: 'parallel',
    isReadOnly: true,
    isDestructive: false,
    describeActivity: () => ({ key: 'signals_gateway.reply.activity.background_job_show' }),
    async execute(_toolCallID, params): Promise<AgentToolResult<ShowBackgroundJobDetailsResult>> {
      const request: RPCRequestInit<'background_agent_job.get'> =
        params.result_offset === undefined
          ? {
              jobId: modelIntegerIDToWire(params.job_id),
              trajectoryLimit: 3,
              trajectoryCursor: ''
            }
          : {
              jobId: modelIntegerIDToWire(params.job_id),
              resultOffset: String(params.result_offset)
            }
      const response = await opts.rpc(rpcMethods.backgroundAgentJobGet, request, { turn: opts.turnStart.turn })
      const status = BackgroundAgentJobStatusSchema.parse(response.status)

      if (params.result_offset !== undefined) {
        if (status !== 'succeeded') {
          throw new Error(`background agent job ${params.job_id} has status ${status}; only succeeded jobs have output`)
        }

        const resultRef = terminalResultRef(response.resultRef, params.job_id)
        const totalBytes = nonNegativeSafeIntegerFromWire(
          response.resultOutputTotalBytes,
          'background_agent_job.result_output_total_bytes'
        )
        return jsonToolResult(
          resultChunk(
            response.title,
            response.resultOutputText,
            params.result_offset,
            totalBytes,
            resultRef,
            modelIntegerIDFromWire(response.workspaceOwnerJobId, 'background_agent_job.workspace_owner_job_id'),
            resultPaths(jsonObjectFromBytes(response.resultPathsJson, 'background_agent_job.result_paths_json'))
          )
        )
      }

      const execution = ExecutionSchema.parse(
        jsonObjectFromBytes(response.executionJson, 'background_agent_job.execution_json')
      )
      const error = jsonObjectFromBytes(response.errorJson, 'background_agent_job.error_json')

      return jsonToolResult({
        title: response.title,
        status,
        result_ref: response.resultRef ? terminalResultRef(response.resultRef, params.job_id) : null,
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
  })
}

function terminalResultRef(resultRef: { type: string; jobId: string } | undefined, jobID: number): ResultRef {
  if (!resultRef || resultRef.type !== 'background_agent_job') {
    throw new Error(`background agent job ${jobID} has no terminal result reference`)
  }
  const resultJobID = modelIntegerIDFromWire(resultRef.jobId, 'background_agent_job.result_ref.job_id')
  if (resultJobID !== jobID) {
    throw new Error(`background agent job ${jobID} returned a mismatched result reference`)
  }
  return { type: 'background_agent_job', job_id: resultJobID }
}

function resultChunk(
  title: string,
  outputWindow: string,
  offset: number,
  totalBytes: number,
  resultRef: ResultRef,
  workspaceOwnerJobID: number,
  paths: ResultPaths
): ShowBackgroundJobResultChunk {
  if (offset > totalBytes) throw invalidResultOffset(offset)
  const windowBytes = utf8ByteLength(outputWindow)
  if (windowBytes > totalBytes - offset || (offset < totalBytes && windowBytes === 0)) {
    throw new Error('background agent job returned an invalid result output window')
  }

  const boundedPaths = fitResultPaths(paths)
  const result = fitToolResultTextWindow(outputWindow, (outputText, truncatedForLimit) => ({
    title,
    status: 'succeeded' as const,
    result_ref: resultRef,
    workspace_owner_job_id: workspaceOwnerJobID,
    ...boundedPaths,
    result: {
      offset,
      output_text: outputText,
      next_offset: truncatedForLimit || offset + windowBytes < totalBytes ? offset + utf8ByteLength(outputText) : null
    }
  }))
  if (!result) throw new Error('background agent job result metadata exceeds the tool output limit')
  return result
}

/**
 * Path lists can each hold 8 KiB, but the whole tool result is capped at
 * 8,000 bytes, so the metadata takes a fixed share and the output window keeps
 * the rest; otherwise a result with many long artifact paths could never be
 * read. The Workspace path always survives; discovery roots go first, then
 * artifacts from the end, and a shortened list keeps its total and the
 * truncated marker.
 */
const RESULT_PATHS_MAX_BYTES = 2_000

function fitResultPaths(paths: ResultPaths): ResultPaths {
  let fitted = paths
  while (utf8ByteLength(JSON.stringify(fitted)) > RESULT_PATHS_MAX_BYTES) {
    const roots = fitted.artifact_roots
    const artifacts = fitted.artifacts
    if (roots && roots.paths.length > 0) {
      fitted = { ...fitted, artifact_roots: { ...roots, paths: roots.paths.slice(0, -1), truncated: true } }
    } else if (artifacts && artifacts.paths.length > 0) {
      fitted = { ...fitted, artifacts: { ...artifacts, paths: artifacts.paths.slice(0, -1), truncated: true } }
    } else {
      return fitted
    }
  }
  return fitted
}

function resultPaths(fields: Record<string, unknown> | null | undefined): ResultPaths {
  const projectPath = fields?.project_path
  return {
    project_path: typeof projectPath === 'string' && projectPath !== '' ? projectPath : null,
    artifacts: backgroundAgentJobPathHandoff(fields?.artifacts) ?? null,
    artifact_roots: backgroundAgentJobPathHandoff(fields?.artifact_roots) ?? null
  }
}

function invalidResultOffset(offset: number): Error {
  return new Error(`background agent job result offset ${offset} is invalid`)
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
