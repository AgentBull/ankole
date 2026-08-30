import { defineWorkerTool, type WorkerAgentTool } from '../../core'
import { modelIntegerIDFromWire } from '../../core/model-integer-id'
import { jsonToolResult } from '../../core/tool-result'
import { createTurnLocalPageRegistry, TurnLocalPageSchema } from '../../core/turn-local-pages'
import { jsonFromBytes } from '../../fabric/envelope_proto'
import type { TurnStart } from '../../lanes/actor_lane'
import { rpcMethods, type RPCRequester, type RPCRequestInit } from '../../lanes/rpc_lane'
import { z } from 'zod'

const WorkflowStatusSchema = z.enum(['running', 'completed', 'failed', 'cancelled'])
const WorkflowRunsSchema = z
  .array(
    z
      .object({
        run_id: z.string(),
        title: z.string(),
        status: WorkflowStatusSchema
      })
      .strict()
  )
  .max(32)

const ListWorkflowsParamsSchema = z
  .object({
    status: z
      .enum(['live', 'done'])
      .describe('Workflow group. live includes running; done includes completed, failed, and cancelled.')
      .optional(),
    page: TurnLocalPageSchema.describe('Turn-local page reference returned by the preceding call.').optional()
  })
  .strict()

type ListWorkflowsResult = {
  workflows: Array<{
    run_id: number
    title: string
    status: z.infer<typeof WorkflowStatusSchema>
  }>
  next_page: string | null
}

export type ListWorkflowsToolOptions = {
  turnStart: TurnStart
  rpc: RPCRequester
}

export function createListWorkflowsTool(
  opts: ListWorkflowsToolOptions
): WorkerAgentTool<typeof ListWorkflowsParamsSchema, ListWorkflowsResult> {
  const pages = createTurnLocalPageRegistry('Workflow')

  return defineWorkerTool({
    name: 'list_workflows',
    description: [
      'List Workflow runs owned by the current Agent.',
      'status defaults to live. live includes running; done includes completed, failed, and cancelled.',
      'Each page contains at most 32 runs, newest first. Use next_page to continue.'
    ].join(' '),
    schema: ListWorkflowsParamsSchema,
    executionMode: 'parallel',
    isReadOnly: true,
    isDestructive: false,
    describeActivity: () => ({ key: 'signals_gateway.reply.activity.workflow_list' }),
    async execute(_toolCallID, params) {
      const request: RPCRequestInit<'workflow.list'> = {
        status: params.status ?? 'live',
        cursor: params.page ? pages.cursorFor(params.page) : ''
      }
      const response = await opts.rpc(rpcMethods.workflowList, request, { turn: opts.turnStart.turn })
      const runs = WorkflowRunsSchema.parse(jsonFromBytes(response.runsJson))

      return jsonToolResult({
        workflows: runs.map(run => ({
          run_id: modelIntegerIDFromWire(run.run_id, 'Workflow run id'),
          title: run.title,
          status: run.status
        })),
        next_page: response.nextCursor ? pages.register(response.nextCursor) : null
      })
    }
  })
}
