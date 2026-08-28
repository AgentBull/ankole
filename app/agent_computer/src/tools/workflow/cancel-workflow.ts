import { defineWorkerTool, type WorkerAgentTool } from '../../core'
import { ModelIntegerID, modelIntegerIDFromWire, modelIntegerIDToWire } from '../../core/model-integer-id'
import { jsonToolResult } from '../../core/tool-result'
import type { TurnStart } from '../../lanes/actor_lane'
import { rpcMethods, type RPCRequester, type RPCRequestInit } from '../../lanes/rpc_lane'
import { z } from 'zod'

const WorkflowStatusSchema = z.enum(['running', 'completed', 'failed', 'cancelled'])
const CancelWorkflowParamsSchema = z
  .object({
    run_id: ModelIntegerID.describe('Workflow run id.')
  })
  .strict()

type CancelWorkflowResult = {
  run_id: number
  status: z.infer<typeof WorkflowStatusSchema>
}

export type CancelWorkflowToolOptions = {
  turnStart: TurnStart
  rpc: RPCRequester
}

export function createCancelWorkflowTool(
  opts: CancelWorkflowToolOptions
): WorkerAgentTool<typeof CancelWorkflowParamsSchema, CancelWorkflowResult> {
  return defineWorkerTool({
    name: 'cancel_workflow',
    description: 'Cancel a running Workflow. A terminal Workflow is an idempotent no-op.',
    schema: CancelWorkflowParamsSchema,
    executionMode: 'sequential',
    isReadOnly: false,
    isDestructive: true,
    describeActivity: () => ({ key: 'signals_gateway.reply.activity.workflow_cancel' }),
    async execute(_toolCallID, params) {
      const request: RPCRequestInit<'workflow.cancel'> = { runId: modelIntegerIDToWire(params.run_id) }
      const response = await opts.rpc(rpcMethods.workflowCancel, request, { turn: opts.turnStart.turn })

      return jsonToolResult({
        run_id: modelIntegerIDFromWire(response.runId, 'Workflow run id'),
        status: WorkflowStatusSchema.parse(response.status)
      })
    }
  })
}
