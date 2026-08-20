import { z } from 'zod'
import { defineWorkerTool, type WorkerAgentTool } from '../../core'
import { ModelIntegerID, modelIntegerIDFromWire, modelIntegerIDToWire } from '../../core/model-integer-id'
import { jsonToolResult } from '../../core/tool-result'
import type { TurnStart } from '../../lanes/actor_lane'
import { rpcMethods, type RPCRequester, type RPCRequestInit } from '../../lanes/rpc_lane'
import { BackgroundAgentJobStatusSchema, type BackgroundAgentJobStatus } from './status'

const StopBackgroundJobParamsSchema = z
  .object({
    job_id: ModelIntegerID.describe('Background agent job id.')
  })
  .strict()

type StopBackgroundJobResult = {
  job_id: number
  status: BackgroundAgentJobStatus
}

export type StopBackgroundJobToolOptions = {
  turnStart: TurnStart
  rpc: RPCRequester
}

export function createStopBackgroundJobTool(
  opts: StopBackgroundJobToolOptions
): WorkerAgentTool<typeof StopBackgroundJobParamsSchema, StopBackgroundJobResult> {
  return defineWorkerTool({
    name: 'stop_background_job',
    description: 'Stop running job. A terminal job is an idempotent no-op.',
    schema: StopBackgroundJobParamsSchema,
    executionMode: 'sequential',
    isReadOnly: false,
    isDestructive: true,
    describeActivity: () => ({ key: 'signals_gateway.reply.activity.background_job_stop' }),
    async execute(_toolCallID, params) {
      const request: RPCRequestInit<'background_agent_job.stop'> = { jobId: modelIntegerIDToWire(params.job_id) }
      const response = await opts.rpc(rpcMethods.backgroundAgentJobStop, request, { turn: opts.turnStart.turn })

      return jsonToolResult({
        job_id: modelIntegerIDFromWire(response.jobId, 'background agent job id'),
        status: BackgroundAgentJobStatusSchema.parse(response.status)
      })
    }
  })
}
