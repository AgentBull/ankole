import type { TurnStart } from '../../actor_lane'
import { runAmbientMayInterveneHandler } from './ambient_turn'
import { runCompressionTurn } from './compression_turn'
import { runTextTurnLoop } from './text_turn'
import { isAmbientMayInterveneTurn, isCompressionTurn } from './turn_control'
import type { TextTurnLoopOptions, TurnHandlerResult } from './turn_options'

export type {
  AgentConversationContextRequester,
  ConversationHistoryRequester,
  ConversationSummaryCommitter,
  CredentialRequester,
  SkillOverlayReplaceRequester,
  SkillOverlayRequester,
  TextTurnLoopOptions,
  TurnHandlerResult
} from './turn_options'
export { runTextTurnLoop } from './text_turn'

/**
 * Dispatches one worker turn by ActorInput type. These are internal Agent
 * Computer handlers: ZMQ delivered only the event batch, while recognizers and
 * follow-up generation stay inside the Agent Computer AI SDK runtime.
 */
export async function runLlmTurnHandlers(turnStart: TurnStart, opts: TextTurnLoopOptions): Promise<TurnHandlerResult> {
  if (isAmbientMayInterveneTurn(turnStart)) {
    return runAmbientMayInterveneHandler(turnStart, opts)
  }

  if (isCompressionTurn(turnStart)) {
    return runCompressionTurn(turnStart, opts)
  }

  return runTextTurnLoop(turnStart, opts)
}
