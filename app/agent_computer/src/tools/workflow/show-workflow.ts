import { utf8ByteLength } from '../../common/text-sanitize'
import { defineWorkerTool, type AgentToolResult, type WorkerAgentTool } from '../../core'
import { ModelIntegerID, modelIntegerIDFromWire, modelIntegerIDToWire } from '../../core/model-integer-id'
import { jsonToolResult } from '../../core/tool-result'
import { fitToolResultTextWindow } from '../../core/tool-result-window'
import { nonNegativeSafeIntegerFromWire } from '../../core/wire-integer'
import { jsonFromBytes, jsonObjectFromBytes } from '../../fabric/envelope_proto'
import type { TurnStart } from '../../lanes/actor_lane'
import { rpcMethods, type RPCRequester, type RPCRequestInit } from '../../lanes/rpc_lane'
import { z } from 'zod'

const WorkflowStatusSchema = z.enum(['running', 'completed', 'failed', 'cancelled'])
const CountsSchema = z
  .object({
    total: z.number().int().nonnegative(),
    queued: z.number().int().nonnegative(),
    running: z.number().int().nonnegative(),
    sleeping: z.number().int().nonnegative(),
    succeeded: z.number().int().nonnegative(),
    failed: z.number().int().nonnegative(),
    cancelled: z.number().int().nonnegative()
  })
  .strict()
const FailureSummariesSchema = z.array(
  z
    .object({
      call_seq: z.number().int().nonnegative(),
      label: z.string().nullable(),
      code: z.string(),
      summary: z.string()
    })
    .strict()
)
const LiveTasksSchema = z.array(
  z
    .object({
      call_seq: z.number().int().nonnegative(),
      label: z.string().nullable(),
      status: z.enum(['queued', 'running', 'sleeping']),
      note: z.string().nullable(),
      attention: z.boolean(),
      sleeping_until: z.string().nullable(),
      wake_count: z.number().int().nonnegative()
    })
    .strict()
)

const ShowWorkflowParamsSchema = z
  .object({
    run_id: ModelIntegerID.describe('Workflow run id.'),
    result_offset: z
      .number()
      .int()
      .nonnegative()
      .max(Number.MAX_SAFE_INTEGER)
      .describe('Stable UTF-8 byte offset into the persisted result. Start with 0 and follow result.next_offset.')
      .optional()
  })
  .strict()

type WorkflowStatus = z.infer<typeof WorkflowStatusSchema>
type WorkflowCounts = z.infer<typeof CountsSchema>
type WorkflowFailureSummary = z.infer<typeof FailureSummariesSchema>[number]
type WorkflowLiveTask = z.infer<typeof LiveTasksSchema>[number]

type ShowWorkflowDetails = {
  run_id: number
  title: string
  status: WorkflowStatus
  counts: WorkflowCounts
  live_tasks: WorkflowLiveTask[]
  failure_summaries: WorkflowFailureSummary[]
  error: Record<string, unknown> | null
}

type ShowWorkflowResultChunk = {
  run_id: number
  title: string
  status: 'completed'
  result: {
    offset: number
    output_text: string
    next_offset: number | null
  }
}

type ShowWorkflowResult = ShowWorkflowDetails | ShowWorkflowResultChunk

export type ShowWorkflowToolOptions = {
  turnStart: TurnStart
  rpc: RPCRequester
}

export function createShowWorkflowTool(
  opts: ShowWorkflowToolOptions
): WorkerAgentTool<typeof ShowWorkflowParamsSchema, ShowWorkflowResult> {
  return defineWorkerTool({
    name: 'show_workflow',
    description: [
      'Show a Workflow run, including task counts, live tasks, bounded failure summaries, and a terminal error.',
      'A sleeping task is still executing: it hibernates until an event wakes it, and its note states what it waits for. A task with attention=true waits for your input; answer it with send_message_to_workflow_task.',
      'To read a completed result, set result_offset to 0, concatenate result.output_text, and pass result.next_offset to the next call until it is null.',
      'Result offsets are stable and can be resumed in a later turn.'
    ].join(' '),
    schema: ShowWorkflowParamsSchema,
    executionMode: 'parallel',
    isReadOnly: true,
    isDestructive: false,
    describeActivity: () => ({ key: 'signals_gateway.reply.activity.workflow_show' }),
    async execute(_toolCallID, params): Promise<AgentToolResult<ShowWorkflowResult>> {
      const request: RPCRequestInit<'workflow.get'> = {
        runId: modelIntegerIDToWire(params.run_id),
        resultOffset: params.result_offset === undefined ? '' : String(params.result_offset)
      }
      const response = await opts.rpc(rpcMethods.workflowGet, request, { turn: opts.turnStart.turn })
      const runID = modelIntegerIDFromWire(response.runId, 'Workflow run id')
      if (runID !== params.run_id) throw new Error(`Workflow ${params.run_id} returned a mismatched run id`)

      const status = WorkflowStatusSchema.parse(response.status)
      if (params.result_offset !== undefined) {
        if (status !== 'completed') {
          throw new Error(`Workflow ${params.run_id} has status ${status}; only completed Workflows have result output`)
        }

        const totalBytes = nonNegativeSafeIntegerFromWire(
          response.resultOutputTotalBytes,
          'workflow.result_output_total_bytes'
        )
        return jsonToolResult(
          resultChunk(runID, response.title, response.resultOutputText, params.result_offset, totalBytes)
        )
      }

      const error = jsonObjectFromBytes(response.errorJson, 'workflow.error_json') ?? {}
      return jsonToolResult({
        run_id: runID,
        title: response.title,
        status,
        counts: CountsSchema.parse(jsonObjectFromBytes(response.countsJson, 'workflow.counts_json')),
        live_tasks: LiveTasksSchema.parse(jsonFromBytes(response.liveTasksJson) ?? []),
        failure_summaries: FailureSummariesSchema.parse(jsonFromBytes(response.failureSummariesJson)),
        error: Object.keys(error).length > 0 ? error : null
      })
    }
  })
}

function resultChunk(
  runID: number,
  title: string,
  outputWindow: string,
  offset: number,
  totalBytes: number
): ShowWorkflowResultChunk {
  if (offset > totalBytes) throw invalidResultOffset(offset)
  const windowBytes = utf8ByteLength(outputWindow)
  if (windowBytes > totalBytes - offset || (offset < totalBytes && windowBytes === 0)) {
    throw new Error('Workflow returned an invalid result output window')
  }

  const result = fitToolResultTextWindow(outputWindow, (outputText, truncatedForLimit) =>
    resultChunkDetails(
      runID,
      title,
      offset,
      outputText,
      truncatedForLimit || offset + windowBytes < totalBytes ? offset + utf8ByteLength(outputText) : null
    )
  )
  if (!result) throw new Error('Workflow result metadata exceeds the tool output limit')
  return result
}

function resultChunkDetails(
  runID: number,
  title: string,
  offset: number,
  outputText: string,
  nextOffset: number | null
): ShowWorkflowResultChunk {
  return {
    run_id: runID,
    title,
    status: 'completed',
    result: { offset, output_text: outputText, next_offset: nextOffset }
  }
}

function invalidResultOffset(offset: number): Error {
  return new Error(`Workflow result offset ${offset} is invalid`)
}
