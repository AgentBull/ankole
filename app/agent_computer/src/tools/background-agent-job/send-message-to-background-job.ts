import { z } from 'zod'
import type { AgentTool, AgentToolResult } from '../../core'
import { ModelIntegerID, modelIntegerIDFromWire, modelIntegerIDToWire } from '../../core/model-integer-id'
import { jsonObjectFromBytes } from '../../fabric/envelope_proto'
import type { TurnStart } from '../../lanes/actor_lane'
import { rpcMethods, type RPCRequester, type RPCRequestInit } from '../../lanes/rpc_lane'
import { modelVisibleTrajectory } from './model-trajectory'

const POLL_INTERVAL_MS = 1_000

const SendMessageToBackgroundJobParamsSchema = z
  .object({
    job_id: ModelIntegerID.describe('BackgroundAgentJob id.'),
    message: z.string().min(1).describe('Message to send to the BackgroundAgentJob.'),
    wait_reply: z.boolean().describe('Wait for the Codex Turn that receives this message.').default(true)
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

const TurnTrajectorySchema = z.object({
  format: z.literal('ankole_chatml'),
  version: z.literal(1),
  messages: z.array(z.record(z.string(), z.unknown()))
})

type BackgroundAgentJobStatus = z.output<typeof BackgroundAgentJobStatusSchema>
type TurnTrajectory = z.output<typeof TurnTrajectorySchema>

type SendMessageToBackgroundJobResult =
  | {
      job_id: number
      status: BackgroundAgentJobStatus
    }
  | {
      job_id: number
      status: BackgroundAgentJobStatus
      last_turn_trajectory: TurnTrajectory
      earlier_trajectory_omitted: boolean
      continues_running: boolean
    }

export type SendMessageToBackgroundJobToolOptions = {
  turnStart: TurnStart
  rpc: RPCRequester
}

export function createSendMessageToBackgroundJobTool(
  opts: SendMessageToBackgroundJobToolOptions
): AgentTool<typeof SendMessageToBackgroundJobParamsSchema, SendMessageToBackgroundJobResult> {
  return {
    name: 'send_message_to_background_job',
    description: [
      'Send one message to a running BackgroundAgentJob or answer a Job that is waiting_on_user.',
      'wait_reply defaults to true and waits for the exact Codex Turn that receives this message.',
      'Use wait_reply=false only when the Turn result is not needed now.'
    ].join(' '),
    schema: SendMessageToBackgroundJobParamsSchema,
    executionMode: 'sequential',
    isReadOnly: false,
    isDestructive: false,
    describeActivity: () => '向后台 Agent 任务发送消息',
    async execute(toolCallID, params, signal): Promise<AgentToolResult<SendMessageToBackgroundJobResult>> {
      const sendRequest: RPCRequestInit<'background_agent_job.message.send'> = {
        jobId: modelIntegerIDToWire(params.job_id),
        message: params.message,
        sourceToolCallId: toolCallID
      }
      const sent = await opts.rpc(rpcMethods.backgroundAgentJobMessageSend, sendRequest, {
        turn: opts.turnStart.turn
      })
      const sentStatus = BackgroundAgentJobStatusSchema.parse(sent.status)

      if (!params.wait_reply) {
        const sentJobID = modelIntegerIDFromWire(sent.jobId, 'background Agent Job id')
        const details = { job_id: sentJobID, status: sentStatus }
        return {
          content: [
            {
              type: 'text',
              text: `Message sent to background job ${sentJobID}. Current job status: ${sentStatus}.`
            }
          ],
          details
        }
      }

      while (true) {
        throwIfAborted(signal)
        const resultRequest: RPCRequestInit<'background_agent_job.message.result'> = {
          jobId: sent.jobId,
          commandEventId: sent.commandEventId
        }
        const response = await opts.rpc(rpcMethods.backgroundAgentJobMessageResult, resultRequest, {
          turn: opts.turnStart.turn
        })

        if (response.ready) {
          const status = BackgroundAgentJobStatusSchema.parse(response.status)
          const trajectory = modelVisibleTrajectory(
            TurnTrajectorySchema.parse(
              jsonObjectFromBytes(
                response.lastTurnTrajectoryJson,
                'background_agent_job.message.result.last_turn_trajectory_json'
              )
            )
          )
          const continuesRunning = status === 'running'
          const details = {
            job_id: modelIntegerIDFromWire(response.jobId, 'background Agent Job id'),
            status,
            last_turn_trajectory: trajectory,
            earlier_trajectory_omitted: response.earlierTrajectoryOmitted,
            continues_running: continuesRunning
          }
          const lines = [`Last turn trajectory:\n${JSON.stringify(trajectory)}`]
          if (response.earlierTrajectoryOmitted) lines.push('Earlier trajectory items were omitted.')
          if (continuesRunning) lines.push('The job continues to run in the background.')

          return {
            content: [{ type: 'text', text: lines.join('\n') }],
            details,
            ...(response.lifecycleActorEventId ? { completeActorEventIDs: [response.lifecycleActorEventId] } : {})
          }
        }

        await pollDelay(signal)
      }
    }
  }
}

function pollDelay(signal?: AbortSignal): Promise<void> {
  if (signal?.aborted) return Promise.reject(abortError(signal))

  return new Promise((resolve, reject) => {
    const timer = setTimeout(done, POLL_INTERVAL_MS)

    function done(): void {
      signal?.removeEventListener('abort', aborted)
      resolve()
    }

    function aborted(): void {
      clearTimeout(timer)
      signal?.removeEventListener('abort', aborted)
      reject(abortError(signal))
    }

    signal?.addEventListener('abort', aborted, { once: true })
  })
}

function throwIfAborted(signal?: AbortSignal): void {
  if (signal?.aborted) throw abortError(signal)
}

function abortError(signal?: AbortSignal): Error {
  return signal?.reason instanceof Error ? signal.reason : new Error('Background job message wait was aborted')
}
