import { z } from 'zod'
import type { AgentTool } from '../../core'
import { ModelIntegerID, modelIntegerIDFromWire, modelIntegerIDToWire } from '../../core/model-integer-id'
import { jsonToolResult } from '../../core/tool-result'
import { assertCodexJobProjectResumeState, codexJobProjectLocation } from '../../core/codex-runner/job-project'
import type { TurnStart } from '../../lanes/actor_lane'
import { rpcMethods, type RPCRequester, type RPCRequestInit } from '../../lanes/rpc_lane'
import { BackgroundAgentJobStatusSchema, type BackgroundAgentJobStatus } from './status'

const RespawnBackgroundJobParamsSchema = z
  .object({
    source_job_id: ModelIntegerID.describe('Terminal background agent job id to respawn.'),
    message: z
      .string()
      .min(1)
      .refine(value => value.trim().length > 0, 'message must not be blank')
  })
  .strict()

const TerminalBackgroundAgentJobStatusSchema = BackgroundAgentJobStatusSchema.extract([
  'succeeded',
  'failed',
  'stopped'
])

type RespawnBackgroundJobResult = {
  job_id: number
  status: BackgroundAgentJobStatus
}

export type RespawnBackgroundJobToolOptions = {
  turnStart: TurnStart
  agentsRoot: string
  rpc: RPCRequester
}

export function createRespawnBackgroundJobTool(
  opts: RespawnBackgroundJobToolOptions
): AgentTool<typeof RespawnBackgroundJobParamsSchema, RespawnBackgroundJobResult> {
  return {
    name: 'respawn_background_job',
    description: [
      'Respawn one non-running background agent job as a new one.',
      'It uses the same workspace and thread, and sends the message as the next user input.'
    ].join(' '),
    schema: RespawnBackgroundJobParamsSchema,
    executionMode: 'sequential',
    isReadOnly: false,
    isDestructive: false,
    describeActivity: () => ({ key: 'signals_gateway.reply.activity.background_job_respawn' }),
    async execute(toolCallID, params) {
      const source = await opts.rpc(
        rpcMethods.backgroundAgentJobGet,
        { jobId: modelIntegerIDToWire(params.source_job_id) },
        { turn: opts.turnStart.turn }
      )
      const sourceStatus = BackgroundAgentJobStatusSchema.parse(source.status)
      if (!TerminalBackgroundAgentJobStatusSchema.safeParse(sourceStatus).success) {
        throw new Error(
          `Background agent job ${params.source_job_id} cannot be respawned from status ${sourceStatus}; expected succeeded, failed, or stopped`
        )
      }
      if (!source.runtimeThreadId) {
        throw new Error(`Background agent job ${params.source_job_id} has no Codex thread to resume`)
      }
      if (!source.workspaceOwnerJobId) {
        throw new Error(`Background agent job ${params.source_job_id} has no workspace owner`)
      }

      const projectLocation = codexJobProjectLocation(opts.agentsRoot, source.agentUid, source.workspaceOwnerJobId)
      assertCodexJobProjectResumeState(projectLocation.hostPath)

      const request: RPCRequestInit<'background_agent_job.respawn'> = {
        sourceJobId: modelIntegerIDToWire(params.source_job_id),
        message: params.message,
        sourceToolCallId: toolCallID
      }
      const response = await opts.rpc(rpcMethods.backgroundAgentJobRespawn, request, {
        turn: opts.turnStart.turn
      })

      return jsonToolResult({
        job_id: modelIntegerIDFromWire(response.jobId, 'background agent job id'),
        status: BackgroundAgentJobStatusSchema.parse(response.status)
      })
    }
  }
}
