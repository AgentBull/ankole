import type { TurnStart } from '../../actor_lane'
import type { FinalProposalBody } from '../../turn_envelopes'
import { runAmbientRecognizer } from './ambient_recognizer'
import { renderMessageWithContext } from './message_context'
import { providerOptionsFromAIGateway, runtimeModelFromAIGatewayApiKey } from './model_runtime'
import { runTextTurnLoop } from './text_turn'
import { AMBIENT_RECOGNIZER_TIMEOUT_MS } from './turn_config'
import { resolveAgentConversationContext, resolveConversationHistory } from './turn_context'
import { userMessage } from './turn_messages'
import type { TextTurnLoopOptions } from './turn_options'

export async function runAmbientMayInterveneHandler(
  turnStart: TurnStart,
  opts: TextTurnLoopOptions
): Promise<FinalProposalBody> {
  const apiKeyRequest = {
    request_id: `ai-gateway-key-${crypto.randomUUID()}`,
    turn: turnStart.turn,
    agent_uid: turnStart.turn.actor.agent_uid,
    session_id: turnStart.turn.actor.session_id
  }
  const apiKey = await opts.requestAIGatewayApiKey(apiKeyRequest)

  if ('code' in apiKey) {
    throw new Error(`AIGateway API key rejected: ${apiKey.code} ${apiKey.message ?? ''}`.trim())
  }

  const lightModelRef = { profile: 'light', provider_id: 'ai_gateway', model: 'light' }
  const lightModel = runtimeModelFromAIGatewayApiKey(lightModelRef, apiKey, 'light', () =>
    opts.requestAIGatewayApiKey({
      ...apiKeyRequest,
      request_id: `ai-gateway-key-${crypto.randomUUID()}`
    })
  )
  const agentConversationContext = await resolveAgentConversationContext(turnStart, opts)
  const history = await resolveConversationHistory(turnStart, opts, 'prompt')
  const recognition = await runAmbientRecognizer({
    headers: lightModel.headers ?? {},
    model: lightModel,
    providerOptions: providerOptionsFromAIGateway(),
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
