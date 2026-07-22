import { z } from 'zod'
import type { AgentTool } from '../../core'
import { ModelIntegerID, modelIntegerIDFromWire, modelIntegerIDToWire } from '../../core/model-integer-id'
import { jsonToolResult } from '../../core/tool-result'
import { assertCodexJobProjectResumeState, codexJobProjectLocation } from '../../core/codex-runner/job-project'
import type { TurnStart } from '../../lanes/actor_lane'
import { rpcMethods, type RPCRequester, type RPCRequestInit } from '../../lanes/rpc_lane'

const RespawnBackgroundJobParamsSchema = z
  .object({
    source_job_id: ModelIntegerID.describe('Terminal BackgroundAgentJob id to respawn.'),
    message: z
      .string()
      .min(1)
      .refine(value => value.trim().length > 0, 'message must not be blank')
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

const TerminalBackgroundAgentJobStatusSchema = z.enum(['succeeded', 'failed', 'stopped'])

type RespawnBackgroundJobResult = {
  job_id: number
  status: z.output<typeof BackgroundAgentJobStatusSchema>
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
    description:
      'Respawn one succeeded, failed, or stopped BackgroundAgentJob as a new Job. The new Job resumes the exact Codex thread and reuses the exact existing workspace. The source Job stays terminal. message is sent verbatim as the next Codex user message.',
    schema: RespawnBackgroundJobParamsSchema,
    executionMode: 'sequential',
    isReadOnly: false,
    isDestructive: false,
    describeActivity: () => 'respawn background agent job',
    async execute(toolCallID, params) {
      const source = await opts.rpc(
        rpcMethods.backgroundAgentJobGet,
        { jobId: modelIntegerIDToWire(params.source_job_id) },
        { turn: opts.turnStart.turn }
      )
      const sourceStatus = BackgroundAgentJobStatusSchema.parse(source.status)
      if (!TerminalBackgroundAgentJobStatusSchema.safeParse(sourceStatus).success) {
        throw new Error(
          `BackgroundAgentJob ${params.source_job_id} cannot be respawned from status ${sourceStatus}; expected succeeded, failed, or stopped`
        )
      }
      if (!source.runtimeThreadId) {
        throw new Error(`BackgroundAgentJob ${params.source_job_id} has no Codex thread to resume`)
      }
      if (!source.workspaceOwnerJobId) {
        throw new Error(`BackgroundAgentJob ${params.source_job_id} has no workspace owner`)
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
        job_id: modelIntegerIDFromWire(response.jobId, 'background Agent Job id'),
        status: BackgroundAgentJobStatusSchema.parse(response.status)
      })
    }
  }
}
