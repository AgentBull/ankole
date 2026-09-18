import type { TurnStart } from '../../lanes/actor_lane'

export type BackgroundAgentJobTurnContext = {
  silentSuccessAllowed: boolean
}

/** Reads the control-plane authorization for a background-job silent result. */
export function backgroundAgentJobTurnContextFromTurnStart(
  turnStart: TurnStart
): BackgroundAgentJobTurnContext | undefined {
  if (turnStart.actor_event.type !== 'background_agent_job.completed') return undefined

  const value = turnStart.request_context?.background_job_silent_success_allowed
  if (value === undefined || value === null) return { silentSuccessAllowed: false }
  if (typeof value !== 'boolean') {
    throw new Error('Background agent job silent-success authorization must be a boolean.')
  }

  return { silentSuccessAllowed: value }
}
