import type { TurnStart } from '../../lanes/actor_lane'
import { runAmbientMayInterveneHandler } from './ambient_turn'
import { runTextTurnLoop } from './text_turn'
import { runCodexJob } from '../codex-runner'
import { runWorkflowTaskTurn } from './workflow_task_turn'
import type { TurnHandlerOptions, TurnHandlerResult } from './turn_options'

/**
 * Dispatches one worker turn by actor event type.
 *
 * AIGateway owns compaction. The worker handles normal text turns and ambient
 * may-intervene events.
 */
export async function runTurnHandlers(turnStart: TurnStart, opts: TurnHandlerOptions): Promise<TurnHandlerResult> {
  if (turnStart.turn.actor.session_id.startsWith('job:')) {
    return runCodexJob(turnStart, opts)
  }

  if (turnStart.turn.actor.session_id.startsWith('wf_task:')) {
    return runWorkflowTaskTurn(turnStart, opts)
  }

  if (isAmbientMayInterveneTurn(turnStart)) {
    return runAmbientMayInterveneHandler(turnStart, opts)
  }

  return runTextTurnLoop(turnStart, opts)
}

function isAmbientMayInterveneTurn(turnStart: TurnStart): boolean {
  return turnStart.actor_event.type === 'im.message.may_intervene'
}
