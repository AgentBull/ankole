import type { TurnStart } from '../../actor_lane'
import type { FinalProposalBody } from '../../turn_envelopes'
import { runAmbientRecognizer } from './ambient_recognizer'
import { renderMessageWithContext } from './message_context'
import { providerOptionsFromCredential, runtimeModelFromCredential } from './model_runtime'
import { runTextTurnLoop } from './text_turn'
import { AMBIENT_RECOGNIZER_TIMEOUT_MS } from './turn_config'
import { resolveAgentConversationContext, resolveConversationHistory } from './turn_context'
import { userMessage } from './turn_messages'
import type { TextTurnLoopOptions } from './turn_options'

export async function runAmbientMayInterveneHandler(
  turnStart: TurnStart,
  opts: TextTurnLoopOptions
): Promise<FinalProposalBody> {
  const lightCredential = await opts.requestCredential({
    request_id: `llm-credential-${crypto.randomUUID()}`,
    turn: turnStart.turn,
    agent_uid: turnStart.turn.actor.agent_uid,
    session_id: turnStart.turn.actor.session_id,
    profile: 'light',
    purpose: 'ai_turn'
  })

  if ('code' in lightCredential) {
    throw new Error(`credential rejected: ${lightCredential.code} ${lightCredential.message ?? ''}`.trim())
  }

  const lightModel = runtimeModelFromCredential(lightCredential)
  const agentConversationContext = await resolveAgentConversationContext(turnStart, opts)
  const history = await resolveConversationHistory(turnStart, opts, 'prompt')
  const recognition = await runAmbientRecognizer({
    headers: lightModel.headers ?? {},
    model: lightModel,
    providerOptions: providerOptionsFromCredential(lightCredential, lightModel.provider),
    agentConversationContext,
    conversationHistory: history,
    turnStart,
    workspaceRoot: opts.workspaceRoot,
    timeoutMs: AMBIENT_RECOGNIZER_TIMEOUT_MS
  })

  if (!recognition.decision.intervene || !recognition.intervention) {
    return { messages: [], reply: null }
  }

  const interventionPrompt = renderMessageWithContext(
    userMessage(recognition.intervention.text),
    recognition.intervention.metadata
  )
  const replyProposal = await runTextTurnLoop(turnStart, {
    ...opts,
    agentConversationContext,
    conversationHistory: history,
    extraMessages: [...(opts.extraMessages ?? []), interventionPrompt]
  })
  const replyText = replyProposal.reply?.text ?? ''

  return {
    ...replyProposal,
    messages: [recognition.intervention.proposedMessage],
    reply: {
      text: replyText,
      content_json: [{ type: 'text', text: replyText }],
      ...(replyProposal.reply?.attachments?.length ? { attachments: replyProposal.reply.attachments } : {})
    }
  }
}
