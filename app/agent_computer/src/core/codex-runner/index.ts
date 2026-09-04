import type { TurnStart } from '../../lanes/actor_lane'
import { rpcMethods } from '../../lanes/rpc_lane'
import { isTerminalBackgroundAgentJobStatus } from '../background-agent-job-documents'
import { modelIntegerIDFromWire, modelIntegerIDToWire } from '../model-integer-id'
import type { CodexJobOptions, TurnHandlerResult } from '../turns/turn_options'
import { prepareCodexJobExecution } from './job/setup'
import { runCodexJobSession } from './job/session'

/**
 * Runs one Background Agent Job Turn.
 * `job/` owns one Job attempt. `runtime/` owns the Agent-scoped app server that
 * Job attempts can share.
 */
export async function runCodexJob(turnStart: TurnStart, opts: CodexJobOptions): Promise<TurnHandlerResult> {
  opts.abortSignal?.throwIfAborted()
  const jobID = jobIDFromTurn(turnStart)
  const job = await opts.rpc(rpcMethods.backgroundAgentJobGet, { jobId: jobID }, { turn: turnStart.turn })
  opts.abortSignal?.throwIfAborted()

  if (isTerminalBackgroundAgentJobStatus(job.status)) {
    return {
      kind: 'noop_completed',
      reason: `background_agent_job_${job.status}`
    }
  }

  const prepared = await prepareCodexJobExecution({ turnStart, opts, jobID, job })
  return runCodexJobSession(turnStart, opts, jobID, job, prepared)
}

function jobIDFromTurn(turnStart: TurnStart): string {
  const sessionID = turnStart.turn.actor.session_id
  if (sessionID.startsWith('job:') && sessionID.length > 'job:'.length) {
    const value = sessionID.slice('job:'.length)
    return modelIntegerIDToWire(modelIntegerIDFromWire(value, 'background Agent Job session id'))
  }
  throw new Error('background agent job turn is missing job id')
}
