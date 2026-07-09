import type { TurnStart } from '../../lanes/actor_lane'
import { runAmbientMayInterveneHandler } from './ambient_turn'
import { runTextTurnLoop } from './text_turn'
import { runSubagentTurn } from './subagent_turn'
import type { TextTurnLoopOptions, TurnHandlerResult } from './turn_options'

/**
 * Dispatches one worker turn by actor event type.
 *
 * AIGateway owns compaction. The worker handles normal text turns and ambient
 * may-intervene events.
 */
export async function runTurnHandlers(turnStart: TurnStart, opts: TextTurnLoopOptions): Promise<TurnHandlerResult> {
  if (turnStart.turn.actor.session_id.startsWith('subagent:')) {
    return runSubagentTurn(turnStart, opts)
  }

  if (isAmbientMayInterveneTurn(turnStart)) {
    return runAmbientMayInterveneHandler(turnStart, opts)
  }

  return runTextTurnLoop(turnStart, opts)
}

function isAmbientMayInterveneTurn(turnStart: TurnStart): boolean {
  return turnStart.actor_event.type === 'im.message.may_intervene'
}
