/**
 * Ambient may-intervene handler.
 *
 * Runs the ambient recognizer, commits the route to the control plane, and
 * applies the first canonical route returned for this event.
 */

import type { TurnStart } from '../../lanes/actor_lane'
import { createCombinedAbortSignal } from '../../common/async'
import { arrayPath, ms, stringArg, type JsonObject as JSONObject } from '@agentbull/active-support'
import { recognizeAmbientIntervention, type AmbientRecognizerDecision } from './ambient_recognizer'
import { acquireTurnAIGatewayAccess } from './turn_ai_gateway_access'
import { runTextTurnLoop } from './text_turn'
import { resolveAgentConversationContext } from './turn_context'
import { rpcMethods, signalChannelRPCRequester } from '../../lanes/rpc_lane'
import type { TextTurnLoopOptions, TurnHandlerResult } from './turn_options'
import {
  ambientActions,
  ambientAuthorities,
  type AmbientAction,
  type AmbientAuthority
} from '../../prompts/ambient_prompt'

const AMBIENT_RECOGNIZER_TIMEOUT_MS = ms('30s')

/**
 * Runs the ambient recognizer, commits its canonical route, and then applies
 * that route. HANDOFF commits its Job steer with the judgment in the control
 * plane, so the Worker never performs the side effect separately.
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

  const committed = await recordAmbientJudgment(turnStart, opts, recognition.decision)
  const action = committed.action

  if (action === 'NOOP') {
    return { kind: 'noop_completed', reason: 'ambient_noop' }
  }

  if (action === 'HANDOFF') {
    return { kind: 'noop_completed', reason: 'ambient_handoff' }
  }

  const result = await runTextTurnLoop(turnStart, {
    ...opts,
    agentConversationContext,
    ambientRoute: { action, authority: committed.authority }
  })

  return result
}

/**
 * Atomically commits the route, cursor, reply anchor, and optional HANDOFF.
 * The first committed route is canonical across Worker retries. A failure must
 * fail the turn because continuing could duplicate a visible reply or lose a
 * HANDOFF while advancing no cursor.
 */
async function recordAmbientJudgment(
  turnStart: TurnStart,
  opts: TextTurnLoopOptions,
  decision: AmbientRecognizerDecision
): Promise<{ action: AmbientAction; authority: AmbientAuthority }> {
  const askedBy = decision.askedBy
  const requestSignalChannelRPC = signalChannelRPCRequester(opts.rpc, turnStart.turn)
  const response = await requestSignalChannelRPC(rpcMethods.signalChannelAmbientJudgmentRecord, {
    reason: decision.reason,
    askedBySourceEntryId: askedBy.state === 'none' ? '' : askedBy.sourceEntryID,
    askedByDegraded: askedBy.state === 'degraded',
    action: decision.action,
    authority: decision.authority,
    handoffJobId: decision.handoffJobID ?? ''
  })

  return canonicalAmbientRoute(response)
}

/** Reads the route that the control plane actually committed. */
export function canonicalAmbientRoute(response: JSONObject): {
  action: AmbientAction
  authority: AmbientAuthority
} {
  const action = stringArg(response, 'action')
  const authority = stringArg(response, 'authority')
  if (
    !ambientActions.includes(action as AmbientAction) ||
    !ambientAuthorities.includes(authority as AmbientAuthority)
  ) {
    throw new Error('ambient judgment response is missing a canonical action or authority')
  }
  if (action !== 'NEW_WORK' && authority !== 'NONE') {
    throw new Error('ambient judgment response returned authority for a non-NEW_WORK action')
  }

  return { action: action as AmbientAction, authority: authority as AmbientAuthority }
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
