import { ms } from '@agentbull/active-support'
import { toError } from '../../common/errors'
import { z } from 'zod'
import { defineWorkerTool, type AgentToolResult, type WorkerAgentTool } from '../../core'
import { ModelIntegerID, modelIntegerIDFromWire, modelIntegerIDToWire } from '../../core/model-integer-id'
import { jsonObjectFromBytes } from '../../fabric/envelope_proto'
import type { TurnStart } from '../../lanes/actor_lane'
import { rpcMethods, type RPCRequester, type RPCRequestInit } from '../../lanes/rpc_lane'
import { modelVisibleTrajectory } from './model-trajectory'
import {
  BackgroundAgentJobStatusSchema,
  BackgroundAgentJobTrajectorySchema,
  isTerminalBackgroundAgentJobStatus,
  type BackgroundAgentJobStatus,
  type BackgroundAgentJobTrajectory
} from '../../core/background-agent-job-documents'

const POLL_INTERVAL_MS = ms('1s')
const DEFAULT_WAIT_TIMEOUT_MS = ms('30s')
const MIN_WAIT_TIMEOUT_MS = ms('10s')
const MAX_WAIT_TIMEOUT_MS = ms('2.5m')

const SendMessageToBackgroundJobParamsSchema = z
  .object({
    job_id: ModelIntegerID.describe('Background agent job id.'),
    message: z.string().min(1).describe('Message to send to the background agent job.'),
    wait_reply: z.boolean().describe('Wait for the Codex Turn that receives this message.').default(true),
    wait_timeout_ms: z
      .number()
      .int()
      .min(MIN_WAIT_TIMEOUT_MS)
      .max(MAX_WAIT_TIMEOUT_MS)
      .describe('Foreground observation window in milliseconds. The background job keeps running after it expires.')
      .default(DEFAULT_WAIT_TIMEOUT_MS)
  })
  .strict()

type WaitOutcome = 'reply_ready' | 'timed_out' | 'steered'

type SendMessageToBackgroundJobResult =
  | {
      job_id: number
      status: BackgroundAgentJobStatus
    }
  | {
      job_id: number
      status: BackgroundAgentJobStatus
      last_turn_trajectory: BackgroundAgentJobTrajectory
      earlier_trajectory_omitted: boolean
      continues_running: boolean
      reply_ready: true
      wait_outcome: 'reply_ready'
    }
  | {
      job_id: number
      status: BackgroundAgentJobStatus
      continues_running: boolean
      reply_ready: false
      wait_outcome: Exclude<WaitOutcome, 'reply_ready'>
    }

export type SendMessageToBackgroundJobToolOptions = {
  turnStart: TurnStart
  rpc: RPCRequester
  waitForSteering?: (signal?: AbortSignal) => Promise<void>
  now?: () => number
}

export function createSendMessageToBackgroundJobTool(
  opts: SendMessageToBackgroundJobToolOptions
): WorkerAgentTool<typeof SendMessageToBackgroundJobParamsSchema, SendMessageToBackgroundJobResult> {
  return defineWorkerTool({
    name: 'send_message_to_background_job',
    description: [
      'Send a message to any live job: queued, running, or waiting_on_user.',
      'A queued message stays behind the original task and is applied when execution starts.',
      'wait_reply (default: true) observes the exact background Turn for up to wait_timeout_ms (default: 30s).',
      'timeout only ends foreground observation while the Job keeps running.',
      'set wait_reply=false if the Turn result is not needed immediately.'
    ].join(' '),
    schema: SendMessageToBackgroundJobParamsSchema,
    executionMode: 'sequential',
    isReadOnly: false,
    isDestructive: false,
    describeActivity: params =>
      params.wait_reply
        ? {
            key: 'signals_gateway.reply.activity.background_job_wait',
            bindings: { job: params.job_id, seconds: formatWaitSeconds(params.wait_timeout_ms) }
          }
        : { key: 'signals_gateway.reply.activity.background_job_send' },
    describeCompletedActivity: (params, details) => {
      if (!params.wait_reply) return { key: 'signals_gateway.reply.activity.background_job_sent' }
      if ('wait_outcome' in details && details.wait_outcome === 'timed_out') {
        return { key: 'signals_gateway.reply.activity.background_job_async' }
      }
      if ('wait_outcome' in details && details.wait_outcome === 'steered') {
        return { key: 'signals_gateway.reply.activity.background_job_steered' }
      }
      return { key: 'signals_gateway.reply.activity.background_job_replied' }
    },
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
        const sentJobID = modelIntegerIDFromWire(sent.jobId, 'background agent job id')
        const details = { job_id: sentJobID, status: sentStatus }
        return {
          content: [
            {
              type: 'text',
              text: `Message stored for background job ${sentJobID}. Current job status: ${sentStatus}.`
            }
          ],
          details
        }
      }

      const now = opts.now ?? Date.now
      const deadlineAt = now() + params.wait_timeout_ms
      const gate = createObservationGate(deadlineAt, now, opts.waitForSteering, signal)
      let lastStatus = sentStatus

      try {
        while (true) {
          const resultRequest: RPCRequestInit<'background_agent_job.message.result'> = {
            jobId: sent.jobId,
            commandEventId: sent.commandEventId
          }
          const observed = await Promise.race([
            opts
              .rpc(rpcMethods.backgroundAgentJobMessageResult, resultRequest, {
                turn: opts.turnStart.turn
              })
              .then(response => ({ kind: 'response' as const, response })),
            gate.outcome
          ])

          if (observed.kind !== 'response') {
            return interruptedWaitResult(observed, sent.jobId, lastStatus)
          }

          const response = observed.response
          lastStatus = BackgroundAgentJobStatusSchema.parse(response.status)

          if (response.ready) {
            const trajectory = modelVisibleTrajectory(
              BackgroundAgentJobTrajectorySchema.parse(
                jsonObjectFromBytes(
                  response.lastTurnTrajectoryJson,
                  'background_agent_job.message.result.last_turn_trajectory_json'
                )
              )
            )
            const continuesRunning = lastStatus === 'running'
            const details = {
              job_id: modelIntegerIDFromWire(response.jobId, 'background agent job id'),
              status: lastStatus,
              last_turn_trajectory: trajectory,
              earlier_trajectory_omitted: response.earlierTrajectoryOmitted,
              continues_running: continuesRunning,
              reply_ready: true as const,
              wait_outcome: 'reply_ready' as const
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

          if (now() >= deadlineAt) {
            return interruptedWaitResult({ kind: 'timed_out' }, sent.jobId, lastStatus)
          }

          const delayed = await pollOrObservationGate(gate, POLL_INTERVAL_MS)
          if (delayed.kind !== 'poll') {
            return interruptedWaitResult(delayed, sent.jobId, lastStatus)
          }
        }
      } finally {
        gate.close()
      }
    }
  })
}

type ObservationOutcome =
  | { kind: 'timed_out' }
  | { kind: 'steered' }
  | { kind: 'aborted'; error: Error }
  | { kind: 'failed'; error: Error }
  | { kind: 'closed' }

type ObservationGate = {
  outcome: Promise<ObservationOutcome>
  close: () => void
}

function createObservationGate(
  deadlineAt: number,
  now: () => number,
  waitForSteering: ((signal?: AbortSignal) => Promise<void>) | undefined,
  signal?: AbortSignal
): ObservationGate {
  const steeringAbort = new AbortController()
  let settled = false
  // oxlint-disable-next-line prefer-const
  let deadlineTimer: ReturnType<typeof setTimeout> | undefined
  let settle!: (outcome: ObservationOutcome) => void
  const outcome = new Promise<ObservationOutcome>(resolve => {
    settle = value => {
      if (settled) return
      settled = true
      if (deadlineTimer) clearTimeout(deadlineTimer)
      signal?.removeEventListener('abort', aborted)
      steeringAbort.abort()
      resolve(value)
    }
  })
  deadlineTimer = setTimeout(() => settle({ kind: 'timed_out' }), Math.max(deadlineAt - now(), 0))
  deadlineTimer.unref?.()

  function aborted(): void {
    settle({ kind: 'aborted', error: abortError(signal) })
  }

  if (signal?.aborted) {
    aborted()
  } else {
    signal?.addEventListener('abort', aborted, { once: true })
  }

  if (waitForSteering) {
    void waitForSteering(steeringAbort.signal).then(
      () => settle({ kind: 'steered' }),
      error => {
        if (!steeringAbort.signal.aborted) {
          settle({ kind: 'failed', error: toError(error) })
        }
      }
    )
  }

  return {
    outcome,
    close: () => settle({ kind: 'closed' })
  }
}

async function pollOrObservationGate(
  gate: ObservationGate,
  intervalMs: number
): Promise<{ kind: 'poll' } | ObservationOutcome> {
  let timer: ReturnType<typeof setTimeout> | undefined
  try {
    return await Promise.race([
      new Promise<{ kind: 'poll' }>(resolve => {
        timer = setTimeout(() => resolve({ kind: 'poll' }), intervalMs)
        timer.unref?.()
      }),
      gate.outcome
    ])
  } finally {
    if (timer) clearTimeout(timer)
  }
}

function interruptedWaitResult(
  outcome: ObservationOutcome,
  jobIDWire: string,
  status: BackgroundAgentJobStatus
): AgentToolResult<SendMessageToBackgroundJobResult> {
  if (outcome.kind === 'aborted' || outcome.kind === 'failed') throw outcome.error
  if (outcome.kind === 'closed') throw new Error('Background job observation closed before producing a result')

  const jobID = modelIntegerIDFromWire(jobIDWire, 'background agent job id')
  const continuesRunning = !isTerminalBackgroundAgentJobStatus(status)
  const waitOutcome = outcome.kind
  const reason =
    waitOutcome === 'steered' ? 'new user steering is pending' : 'the foreground observation window expired'
  const details = {
    job_id: jobID,
    status,
    continues_running: continuesRunning,
    reply_ready: false as const,
    wait_outcome: waitOutcome
  }

  return {
    content: [
      {
        type: 'text',
        text: [
          `Stopped waiting for background job ${jobID} because ${reason}.`,
          `Current job status: ${status}.`,
          'The message is already stored; do not resend it.',
          ...(continuesRunning ? ['The job continues to run in the background.'] : [])
        ].join('\n')
      }
    ],
    details
  }
}

function formatWaitSeconds(timeoutMs: number): number {
  return timeoutMs / 1_000
}

function abortError(signal?: AbortSignal): Error {
  return signal?.reason instanceof Error ? signal.reason : new Error('Background job message wait was aborted')
}
