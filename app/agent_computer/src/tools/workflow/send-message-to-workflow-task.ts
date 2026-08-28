import { z } from 'zod'
import { defineWorkerTool, type AgentToolResult, type WorkerAgentTool } from '../../core'
import { ModelIntegerID, modelIntegerIDFromWire, modelIntegerIDToWire } from '../../core/model-integer-id'
import { jsonToolResult } from '../../core/tool-result'
import type { TurnStart } from '../../lanes/actor_lane'
import { rpcMethods, type RPCRequester, type RPCRequestInit } from '../../lanes/rpc_lane'

const SendMessageToWorkflowTaskParamsSchema = z
  .object({
    run_id: ModelIntegerID.describe('Workflow run id.'),
    call_seq: z.number().int().nonnegative().describe('Task call_seq from show_workflow.'),
    message: z.string().min(1).max(8_000).describe('Message delivered to the task.')
  })
  .strict()

type SendMessageToWorkflowTaskResult = {
  run_id: number
  call_seq: number
  task_status: string
}

export type SendMessageToWorkflowTaskToolOptions = {
  turnStart: TurnStart
  rpc: RPCRequester
}

/** Appends one asynchronous owner message to a live Workflow task session. */
export function createSendMessageToWorkflowTaskTool(
  opts: SendMessageToWorkflowTaskToolOptions
): WorkerAgentTool<typeof SendMessageToWorkflowTaskParamsSchema, SendMessageToWorkflowTaskResult> {
  return defineWorkerTool({
    name: 'send_message_to_workflow_task',
    description: [
      'Send a message to one live Workflow task, addressed by run_id and call_seq from show_workflow.',
      'The send is asynchronous and returns immediately: a sleeping task wakes with the message, a running task receives it when its current turn ends.',
      'Use it to answer a task that sleeps with attention, or to steer a task mid-run. It cannot reach a terminal task.'
    ].join(' '),
    schema: SendMessageToWorkflowTaskParamsSchema,
    executionMode: 'sequential',
    isReadOnly: false,
    isDestructive: false,
    describeActivity: () => ({ key: 'signals_gateway.reply.activity.workflow_task_message' }),
    async execute(toolCallID, params): Promise<AgentToolResult<SendMessageToWorkflowTaskResult>> {
      const request: RPCRequestInit<'workflow.task.message.send'> = {
        runId: modelIntegerIDToWire(params.run_id),
        callSeq: params.call_seq,
        message: params.message,
        sourceToolCallId: toolCallID
      }
      const response = await opts.rpc(rpcMethods.workflowTaskMessageSend, request, { turn: opts.turnStart.turn })

      return jsonToolResult({
        run_id: modelIntegerIDFromWire(response.runId, 'Workflow run id'),
        call_seq: response.callSeq,
        task_status: response.taskStatus
      })
    }
  })
}
