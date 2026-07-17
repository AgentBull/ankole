/**
 * Ambient may-intervene handler.
 *
 * Runs the ambient recognizer and, if intervention is recommended, starts a
 * text turn with the intervention prompt.
 */

import type { TurnStart } from '../../lanes/actor_lane'
import { createCombinedAbortSignal } from '../../common/async'
import { arrayPath } from '@pleisto/active-support'
import { recognizeAmbientIntervention } from './ambient_recognizer'
import { acquireTurnAIGatewayAccess } from './turn_ai_gateway_access'
import { runTextTurnLoop } from './text_turn'
import { resolveAgentConversationContext } from './turn_context'
import type { TextTurnLoopOptions, TurnHandlerResult } from './turn_options'

const AMBIENT_RECOGNIZER_TIMEOUT_MS = 30_000

/**
 * Runs the ambient recognizer and, only when it chooses to intervene, delegates
 * to the normal text-turn path with extra context.
 *
 * Silent ambient observations complete as no-ops so normal chat traffic does not
 * force the agent to speak.
 */
export async function runAmbientMayInterveneHandler(
  turnStart: TurnStart,
  opts: TextTurnLoopOptions
): Promise<TurnHandlerResult> {
  const modelRef = turnStart.model_ref
  if (!modelRef) {
    throw new Error('ambient turn is missing a real model_ref')
  }

  const { model } = await acquireTurnAIGatewayAccess(turnStart, {
    requestAIGatewayAPIKey: opts.requestAIGatewayAPIKey
  })
  const agentConversationContext = await resolveAgentConversationContext(turnStart, opts)

  const recognizerTimeout = createCombinedAbortSignal(opts.abortSignal, AMBIENT_RECOGNIZER_TIMEOUT_MS)
  const recognition = await recognizeAmbientIntervention(
    {
      turnStart,
      model,
      historyMessages: ambientHistoryMessages(turnStart),
      agentConversationContext
    },
    { abortSignal: recognizerTimeout.signal }
  ).finally(() => recognizerTimeout.cleanup())

  if (recognition.messages.length === 0) {
    return { kind: 'noop_completed', reason: 'ambient_silent' }
  }

  // Feed intervention messages as extra context and run a text turn.
  const result = await runTextTurnLoop(turnStart, {
    ...opts,
    agentConversationContext,
    extraMessages: recognition.messages
  })

  return result
}

/**
 * Reads shared-channel and ambient observation rows from the event payload.
 */
function ambientHistoryMessages(turnStart: TurnStart): unknown[] {
  const payload = turnStart.actor_event.payload_json
  return [
    ...arrayPath(payload, ['data', 'channel_context', 'messages']),
    ...arrayPath(payload, ['data', 'unreplied_messages'])
  ]
}
