/**
 * Ambient may-intervene handler.
 *
 * Runs the ambient recognizer, reports the judgment to the control plane, and
 * only when intervention is recommended starts a text turn with the
 * intervention prompt.
 */

import type { TurnStart } from '../../lanes/actor_lane'
import { createCombinedAbortSignal } from '../../common/async'
import { arrayPath } from '@agentbull/active-support'
import { recognizeAmbientIntervention, type AmbientRecognizerDecision } from './ambient_recognizer'
import { acquireTurnAIGatewayAccess } from './turn_ai_gateway_access'
import { runTextTurnLoop } from './text_turn'
import { resolveAgentConversationContext } from './turn_context'
import { rpcMethods } from '../../lanes/rpc_lane'
import type { TextTurnLoopOptions, TurnHandlerResult } from './turn_options'

const AMBIENT_RECOGNIZER_TIMEOUT_MS = 30_000

/**
 * Runs the ambient recognizer and, only when it chooses to intervene, delegates
 * to the normal text-turn path with extra context.
 *
 * Silent ambient observations complete as no-ops so normal chat traffic does not
 * force the agent to speak. Every decision is reported to the control plane,
 * which stores the judgment, advances the channel ambient cursor, and applies
 * an accepted asked_by attribution as the reply anchor.
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

  await recordAmbientJudgment(turnStart, opts, recognition.decision)

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
 * Reports the recognizer decision over the RPC lane.
 *
 * The judgment write also advances the channel cursor and sets the reply
 * anchor, but a failed report must not consume or block the turn: the cursor
 * heals on the next judgment and the anchor merely falls back to the batch
 * tail, so the failure is logged and the turn continues.
 */
async function recordAmbientJudgment(
  turnStart: TurnStart,
  opts: TextTurnLoopOptions,
  decision: AmbientRecognizerDecision
): Promise<void> {
  const askedBy = decision.askedBy

  try {
    await opts.rpc(
      rpcMethods.signalChannelAmbientJudgmentRecord,
      {
        decision: decision.intervene ? 'intervene' : 'silent',
        reason: decision.reason,
        askedBySourceEntryId: askedBy.state === 'none' ? '' : askedBy.sourceEntryID,
        askedByDegraded: askedBy.state === 'degraded'
      },
      { turn: turnStart.turn }
    )
  } catch (error) {
    opts.logger?.warning('worker.ambient_judgment_record_failed', 'ambient judgment record failed', {
      actor_event_id: turnStart.turn.actor_event_id,
      error: error instanceof Error ? error.message : String(error)
    })
  }
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
