import { z } from 'zod'
import { defineWorkerTool, type AgentToolResult, type WorkerAgentTool } from '../../core'
import { jsonToolResult } from '../../core/tool-result'
import { jsonBytes } from '../../fabric/envelope_proto'
import type { ActorTurnRef } from '../../lanes/actor_lane'
import { rpcMethods, type RPCRequester, type RPCRequestInit, type RPCResponseOf } from '../../lanes/rpc_lane'

const SubmitResultParams = z.object({ result: z.json() }).strict()
const terminalTaskStatuses = new Set(['succeeded', 'failed', 'cancelled'])

type SubmitResultParams = z.output<typeof SubmitResultParams>
type SubmitResultDetails = {
  accepted: boolean
  task_status: string
}

export type CreateWorkflowSubmitResultToolOptions = {
  callId: string
  resultSchema: Record<string, unknown>
  rpc: RPCRequester
  turn: ActorTurnRef
  onTerminal: () => void
  onRequeued: (error: WorkflowTaskRequeuedError) => void
}

export class WorkflowTaskRequeuedError extends Error {
  readonly code = 'workflow_task_requeued'
  readonly retryable = true

  constructor(readonly callId: string) {
    super(`Workflow task ${callId} was requeued for another attempt.`)
    this.name = 'WorkflowTaskRequeuedError'
  }
}

/** Creates the only durable-write tool available inside a Workflow task turn. */
export function createWorkflowSubmitResultTool(
  opts: CreateWorkflowSubmitResultToolOptions
): WorkerAgentTool<typeof SubmitResultParams, SubmitResultDetails> {
  return defineWorkerTool({
    name: 'submit_result',
    description: [
      'Submit the final result of this Workflow task.',
      'Call this tool only after the task is complete. A schema rejection is recoverable: correct the result and call the tool again.',
      'An accepted result ends this task turn.'
    ].join(' '),
    schema: SubmitResultParams,
    jsonSchema: resultToolJSONSchema(opts.resultSchema),
    strict: true,
    executionMode: 'sequential',
    isReadOnly: false,
    isDestructive: false,
    describeActivity: () => ({ key: 'signals_gateway.reply.activity.submit_result' }),
    async execute(_toolCallID, params): Promise<AgentToolResult<SubmitResultDetails>> {
      const response = await opts.rpc(rpcMethods.workflowTaskResultSubmit, successRequest(opts.callId, params.result), {
        turn: opts.turn
      })
      const details = submissionDetails(response, opts.callId, opts.onRequeued)
      opts.onTerminal()
      return jsonToolResult(details, { terminate: true })
    }
  })
}

/** Commits the bounded failure used when the model never calls submit_result. */
export async function submitWorkflowTaskFailure(
  opts: Pick<CreateWorkflowSubmitResultToolOptions, 'callId' | 'rpc' | 'turn'>,
  failure: { code: string; summary: string; retryable: boolean }
): Promise<SubmitResultDetails> {
  const response = await opts.rpc(
    rpcMethods.workflowTaskResultSubmit,
    {
      callId: opts.callId,
      ok: false,
      valueJson: new Uint8Array(0),
      code: failure.code,
      summary: failure.summary,
      retryable: failure.retryable
    },
    { turn: opts.turn }
  )
  return submissionDetails(response, opts.callId)
}

function resultToolJSONSchema(resultSchema: Record<string, unknown>): Record<string, unknown> {
  return {
    type: 'object',
    properties: { result: resultSchema },
    required: ['result'],
    additionalProperties: false
  }
}

function successRequest(
  callId: string,
  result: SubmitResultParams['result']
): RPCRequestInit<'workflow.task.result.submit'> {
  return {
    callId,
    ok: true,
    valueJson: jsonBytes(result),
    code: '',
    summary: '',
    retryable: false
  }
}

function submissionDetails(
  response: RPCResponseOf<'workflow.task.result.submit'>,
  callId: string,
  onRequeued?: (error: WorkflowTaskRequeuedError) => void
): SubmitResultDetails {
  if (response.taskStatus === 'queued') {
    const error = new WorkflowTaskRequeuedError(callId)
    onRequeued?.(error)
    throw error
  }
  if (!terminalTaskStatuses.has(response.taskStatus)) {
    throw new Error(`Workflow task result submission returned invalid status: ${response.taskStatus || '<empty>'}`)
  }
  return { accepted: response.accepted, task_status: response.taskStatus }
}
