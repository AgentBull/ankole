import type { TurnStart } from '../../lanes/actor_lane'
import { rpcMethods, type BackgroundAgentJobStatus } from '../../lanes/rpc_lane'
import type { CodexJobOptions, TurnHandlerResult } from '../turns/turn_options'
import { prepareCodexJobExecution } from './setup'
import { runCodexJobSession } from './session'

const terminalStatuses = new Set<BackgroundAgentJobStatus>(['succeeded', 'failed', 'stopped'])

export { configureCodexSkills } from './session'

export async function runCodexJob(turnStart: TurnStart, opts: CodexJobOptions): Promise<TurnHandlerResult> {
  const jobID = jobIDFromTurn(turnStart)
  const job = await opts.rpc(rpcMethods.backgroundAgentJobGet, { jobId: jobID }, { turn: turnStart.turn })

  if (terminalStatuses.has(job.status as BackgroundAgentJobStatus)) {
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
  if (typeof fromContext === 'string' && fromContext) return fromContext
  const sessionID = turnStart.turn.actor.session_id
  if (sessionID.startsWith('job:') && sessionID.length > 'job:'.length) {
    return sessionID.slice('job:'.length)
  }
  throw new Error('background agent job turn is missing job id')
}
