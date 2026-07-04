import type { TurnStart } from '../../lanes/actor_lane'
import { buildAmbientRecognizerSystemPrompt, buildAmbientRecognizerUserPrompt } from '../../prompts/ambient_prompt'
import { arrayPath, objectPath, safeJsonStringify, stringArg, isRecord } from '../../common/json-utils'
import { currentChannelFromTurnStart, actorEventText } from './actor_event_text'
import { assistantText, callModel, type Message, type ModelConfig, userMessage } from '../llm'
import type { AgentConversationContext } from '../../lanes/rpc_lane'

export interface AmbientRecognizerInput {
  turnStart: TurnStart
  model: ModelConfig
  historyMessages: unknown[]
  agentConversationContext: AgentConversationContext
  environmentInfoLines?: string[]
}

export interface AmbientRecognizerResult {
  messages: Message[]
}

/**
 * Decides whether an ambient observation should become a visible reply.
 *
 * The recognizer is intentionally a separate structured-output call so the main
 * text turn only runs when there is a clear intervention decision.
 */
export async function recognizeAmbientIntervention(
  input: AmbientRecognizerInput,
  opts?: { abortSignal?: AbortSignal }
): Promise<AmbientRecognizerResult> {
  const turnStart = input.turnStart
  const context = input.agentConversationContext
  const currentChannel = currentChannelFromTurnStart(turnStart)
  const decisionInput = ambientDecisionInput(input)

  const result = await callModel(input.model, {
    instructions: buildAmbientRecognizerSystemPrompt({
      agentUid: turnStart.turn.actor.agent_uid,
      channelLabel: currentChannel?.name ?? currentChannel?.id,
      conversationId: context.conversation?.id ?? turnStart.turn.actor.session_id,
      displayName: context.agent?.display_name ?? turnStart.turn.actor.agent_uid,
      mission: context.mission,
      soul: context.soul ?? '',
      timezone: context.conversation?.timezone ?? 'UTC'
    }),
    messages: [userMessage(buildAmbientRecognizerUserPrompt(JSON.stringify(decisionInput, null, 2)))],
    maxOutputTokens: 300,
    temperature: 0,
    text: ambientDecisionTextFormat,
    abortSignal: opts?.abortSignal
  })

  const decision = parseAmbientDecision(assistantText(result.message))
  if (!decision.intervene) return { messages: [] }

  return {
    messages: [
      userMessage(
        [
          'Ambient recognizer decision: intervene.',
          `Reason: ${decision.reason || 'The current observed messages need a visible reply.'}`,
          'Use the current observed messages as the task and write the visible reply now.'
        ].join('\n')
      )
    ]
  }
}

const ambientDecisionTextFormat = {
  format: {
    type: 'json_schema',
    name: 'ambient_intervention_decision',
    strict: true,
    schema: {
      type: 'object',
      properties: {
        intervene: { type: 'boolean' },
        reason: { type: 'string' }
      },
      required: ['intervene', 'reason'],
      additionalProperties: false
    }
  }
} as const

/**
 * Builds the JSON payload inspected by the ambient recognizer model.
 */
function ambientDecisionInput(input: AmbientRecognizerInput): Record<string, unknown> {
  const payload = input.turnStart.actor_event.payload_json
  const recentHistory = arrayPath(payload, ['data', 'recent_history'])
  const earlierObservedMessages = arrayPath(payload, ['data', 'earlier_observed_messages'])

  return {
    current_input_text: actorEventText(payload, input.turnStart.actor_event.type),
    current_observed_messages: arrayPath(payload, ['data', 'observed_messages']),
    entries: arrayPath(payload, ['data', 'entries']),
    ambient_batch: objectPath(payload, ['data', 'ambient_batch']),
    channel: objectPath(payload, ['data', 'channel']),
    source_entry_id: input.turnStart.actor_event.source_entry_id,
    provider_thread_id: input.turnStart.actor_event.provider_thread_id,
    environment_info: input.environmentInfoLines ?? [],
    recent_history: recentHistory.length > 0 ? recentHistory : input.historyMessages,
    earlier_observed_messages: earlierObservedMessages
  }
}

/**
 * Parses the recognizer's structured JSON decision.
 */
function parseAmbientDecision(text: string): { intervene: boolean; reason: string } {
  const parsed = parseJsonObject(text)
  return {
    intervene: parsed.intervene === true,
    reason: stringArg(parsed, 'reason') ?? ''
  }
}

/**
 * Recovers a JSON object from model output that may contain extra text despite
 * the structured-output request.
 */
function parseJsonObject(text: string) {
  const trimmed = text.trim()
  if (!trimmed) return {}

  try {
    const parsed = JSON.parse(trimmed)
    return isRecord(parsed) ? parsed : {}
  } catch {
    const start = trimmed.indexOf('{')
    const end = trimmed.lastIndexOf('}')
    if (start >= 0 && end > start) {
      try {
        const parsed = JSON.parse(trimmed.slice(start, end + 1))
        return isRecord(parsed) ? parsed : {}
      } catch {
        return { reason: safeJsonStringify({ invalid_json: trimmed }) }
      }
    }
    return { reason: safeJsonStringify({ invalid_json: trimmed }) }
  }
}
