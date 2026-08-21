import type { TurnStart } from '../../lanes/actor_lane'
import { rpcMethods } from '../../lanes/rpc_lane'
import { isTerminalBackgroundAgentJobStatus } from '../background-agent-job-documents'
import { modelIntegerIDFromWire, modelIntegerIDToWire } from '../model-integer-id'
import type { CodexJobOptions, TurnHandlerResult } from '../turns/turn_options'
import { prepareCodexJobExecution } from './setup'
import { runCodexJobSession } from './session'

export { verifiedCodexSkills } from './session'

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

  const prepared = await prepareCodexJobExecution({
    turnStart,
    opts,
    jobID,
    job
  })
  return runCodexJobSession(prepared)
}

function jobIDFromTurn(turnStart: TurnStart): string {
  const fromContext = turnStart.request_context?.job_id
  if (typeof fromContext === 'number') return modelIntegerIDToWire(fromContext)
  const sessionID = turnStart.turn.actor.session_id
  if (sessionID.startsWith('job:') && sessionID.length > 'job:'.length) {
    const value = sessionID.slice('job:'.length)
    return modelIntegerIDToWire(modelIntegerIDFromWire(value, 'background Agent Job session id'))
  }
  throw new Error('background agent job turn is missing job id')
}
