import type { TurnStart } from '../../actor_lane'
import { runAmbientMayInterveneHandler } from './ambient_turn'
import { runTextTurnLoop } from './text_turn'
import { isAmbientMayInterveneTurn } from './turn_control'
import type { TextTurnLoopOptions, TurnHandlerResult } from './turn_options'

export type {
  AgentConversationContextRequester,
  AIGatewayApiKeyRequester,
  SkillOverlayReplaceRequester,
  SkillOverlayRequester,
  TextTurnLoopOptions,
  TurnHandlerResult
} from './turn_options'
export { runTextTurnLoop } from './text_turn'

/**
 * Dispatches one worker turn by actor event type.
 *
 * AIGateway owns compaction. The worker handles normal text turns and ambient
 * may-intervene events.
 */
export async function runTurnHandlers(turnStart: TurnStart, opts: TextTurnLoopOptions): Promise<TurnHandlerResult> {
  if (isAmbientMayInterveneTurn(turnStart)) {
    return runAmbientMayInterveneHandler(turnStart, opts)
  }

  return runTextTurnLoop(turnStart, opts)
}
