import { z } from 'zod'
import type { AgentTool } from '../../core'
import { ModelIntegerID, modelIntegerIDFromWire, modelIntegerIDToWire } from '../../core/model-integer-id'
import { jsonToolResult } from '../../core/tool-result'
import type { TurnStart } from '../../lanes/actor_lane'
import { rpcMethods, type RPCRequester, type RPCRequestInit } from '../../lanes/rpc_lane'

const StopBackgroundJobParamsSchema = z
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

type StopBackgroundJobResult = {
  job_id: number
  status: z.output<typeof BackgroundAgentJobStatusSchema>
}

export type StopBackgroundJobToolOptions = {
  turnStart: TurnStart
  rpc: RPCRequester
}

export function createStopBackgroundJobTool(
  opts: StopBackgroundJobToolOptions
): AgentTool<typeof StopBackgroundJobParamsSchema, StopBackgroundJobResult> {
  return {
    name: 'stop_background_job',
    description:
      'Stop one queued, running, or waiting_on_user BackgroundAgentJob. A terminal Job is an idempotent no-op.',
    schema: StopBackgroundJobParamsSchema,
    executionMode: 'sequential',
    isReadOnly: false,
    isDestructive: true,
    describeActivity: () => 'stop background agent job',
    async execute(_toolCallID, params) {
      const request: RPCRequestInit<'background_agent_job.stop'> = { jobId: modelIntegerIDToWire(params.job_id) }
      const response = await opts.rpc(rpcMethods.backgroundAgentJobStop, request, { turn: opts.turnStart.turn })

      return jsonToolResult({
        job_id: modelIntegerIDFromWire(response.jobId, 'background Agent Job id'),
        status: BackgroundAgentJobStatusSchema.parse(response.status)
      })
    }
  }
}
