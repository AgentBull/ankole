import {
  arrayPath,
  firstString,
  isRecord,
  recordValue,
  safeJsonParse as safeJSONParse,
  safeJsonStringify as safeJSONStringify,
  stringArg,
  type JsonObject as JSONObject
} from '@agentbull/active-support'
import type { TurnStart } from '../../lanes/actor_lane'
import { buildAmbientRecognizerSystemPrompt, buildAmbientRecognizerUserPrompt } from '../../prompts/ambient_prompt'
import { formatZonedDate, formatZonedDateTime, zonedDateTimeParts } from '../../prompts/zoned_time'
import { assistantText, callModel, type Message, type ModelConfig, userMessage } from '../llm'
import type { AgentConversationContextResponse } from '../../lanes/rpc_lane'

export interface AmbientRecognizerInput {
  turnStart: TurnStart
  model: ModelConfig
  historyMessages: unknown[]
  agentConversationContext: AgentConversationContextResponse
}

/**
 * Outcome of validating the recognizer's asked_by proposal against the judged
 * batch. Only an accepted attribution may become a reply anchor; a degraded
 * one is recorded for observability and the wake stays proactive.
 */
export type AskedByResolution =
  | { state: 'none' }
  | { state: 'accepted'; sourceEntryID: string; speaker: string; text: string }
  | { state: 'degraded'; sourceEntryID: string }

export interface AmbientRecognizerDecision {
  intervene: boolean
  reason: string
  askedBy: AskedByResolution
}

export interface AmbientRecognizerResult {
  decision: AmbientRecognizerDecision
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
  opts?: { abortSignal?: AbortSignal; currentTime?: Date }
): Promise<AmbientRecognizerResult> {
  const turnStart = input.turnStart
  const context = input.agentConversationContext
  const originChannel = context.conversation?.originChannel
  const timezone = context.conversation?.timezone ?? 'UTC'
  const displayName = context.agent?.displayName ?? turnStart.turn.actor.agent_uid
  const currentTime = (opts?.currentTime ?? new Date()).toISOString()
  const window = ambientObservationWindow(input, timezone, currentTime)

  const result = await callModel(input.model, {
    instructions: buildAmbientRecognizerSystemPrompt({
      displayName,
      mission: context.mission,
      soul: context.soul ?? ''
    }),
    messages: [
      userMessage(
        buildAmbientRecognizerUserPrompt({
          standingOrders: standingOrdersFromPayload(turnStart),
          backdrop: window.backdrop.map(transcriptLine),
          newMessages: window.delta.map(deltaTranscriptLine),
          unrepliedCount: unrepliedCountFromPayload(turnStart),
          currentTime: formatZonedDateTime(currentTime, timezone) ?? currentTime,
          groupName: originChannel?.label || undefined,
          adapter: originChannel?.adapter || undefined,
          timezone
        })
      )
    ],
    maxOutputTokens: 300,
    temperature: 0,
    text: ambientDecisionTextFormat,
    abortSignal: opts?.abortSignal
  })

  const parsed = parseAmbientDecision(assistantText(result.message))
  const askedBy = parsed.intervene ? resolveAskedBy(parsed.askedBy, window.delta) : { state: 'none' as const }
  const decision: AmbientRecognizerDecision = {
    intervene: parsed.intervene,
    reason: parsed.reason,
    askedBy
  }

  if (!decision.intervene) return { decision, messages: [] }

  return { decision, messages: [userMessage(interventionFraming(decision))] }
}

/**
 * Validates the model's asked_by proposal against the not-yet-judged messages.
 *
 * The attribution is accepted only when it names a human message in the judged
 * batch whose speaker is still the latest human speaker; a reply anchored to
 * an older ask after the room moved on reads as noise, so that case degrades
 * to a proactive wake.
 */
export function resolveAskedBy(proposed: string | undefined, delta: TranscriptMessage[]): AskedByResolution {
  const sourceEntryID = proposed
    ?.trim()
    .replace(/^\[?id:/, '')
    .replace(/\]$/, '')
    .trim()
  if (!sourceEntryID) return { state: 'none' }

  const humans = delta.filter(message => message.role === 'human' && message.text.trim() !== '')
  const asking = humans.find(message => message.sourceEntryID === sourceEntryID)
  if (!asking) return { state: 'degraded', sourceEntryID }

  const newest = humans[humans.length - 1]
  if (!newest || newest.speaker !== asking.speaker) return { state: 'degraded', sourceEntryID }

  return { state: 'accepted', sourceEntryID, speaker: asking.speaker, text: asking.text }
}

function interventionFraming(decision: AmbientRecognizerDecision): string {
  const lines = [
    'Ambient recognizer decision: intervene.',
    `Reason: ${decision.reason || 'The current observed messages need a visible reply.'}`
  ]

  if (decision.askedBy.state === 'accepted') {
    lines.push(
      `You are answering ${decision.askedBy.speaker}, who asked: ${truncateQuote(decision.askedBy.text)}`,
      'The platform anchors your visible reply to that message; answer it directly.'
    )
  } else {
    lines.push('Use the group conversation from this ambient turn as the task and write the visible group reply now.')
  }

  return lines.join('\n')
}

function truncateQuote(text: string): string {
  const trimmed = text.trim()
  return trimmed.length > 500 ? `${trimmed.slice(0, 500)}…` : trimmed
}

const ambientDecisionTextFormat = {
  format: {
    type: 'json_schema',
    name: 'ambient_intervention_decision',
    strict: true,
    schema: {
      type: 'object',
      properties: {
        reason: {
          type: 'string',
          description: 'One sentence explaining why the agent should or should not speak now.'
        },
        should_proactively_speak: {
          type: 'boolean',
          description: 'True when the agent should proactively speak in the group; false when it should stay silent.'
        },
        asked_by: {
          type: ['string', 'null'],
          description:
            'When speaking because one NEW message directly asks or addresses the agent, the id tag of that message. Null for proactive wakes.'
        }
      },
      required: ['reason', 'should_proactively_speak', 'asked_by'],
      additionalProperties: false
    }
  }
} as const

/**
 * The judged observation window: `delta` holds not-yet-judged messages and
 * `backdrop` holds already-judged context rows supplied by the control plane.
 */
function ambientObservationWindow(
  input: AmbientRecognizerInput,
  timezone: string,
  currentTime: string
): { delta: TranscriptMessage[]; backdrop: TranscriptMessage[] } {
  const payload = input.turnStart.actor_event.payload_json
  const currentDate = formatZonedDate(currentTime, timezone)
  const toTranscript = (values: unknown[]): TranscriptMessage[] =>
    dedupeTranscriptMessages(
      values
        .map((value, index) => transcriptMessage(value, index, timezone, currentDate))
        .filter((message): message is TranscriptMessage => message !== undefined)
    ).sort((a, b) => a.sortTime - b.sortTime || a.index - b.index)

  const delta = toTranscript(arrayPath(payload, ['data', 'observed_messages']))
  if (delta.length > 0) {
    return { delta, backdrop: toTranscript(arrayPath(payload, ['data', 'backdrop_messages'])) }
  }

  // Older event payloads carry no cursor split; fall back to the merged shape.
  const fallback = [
    ...arrayPath(payload, ['data', 'channel_context', 'messages']),
    ...arrayPath(payload, ['data', 'unreplied_messages'])
  ]
  return {
    delta: toTranscript(fallback.length > 0 ? fallback : input.historyMessages),
    backdrop: []
  }
}

function standingOrdersFromPayload(turnStart: TurnStart): string | undefined {
  const payload = turnStart.actor_event.payload_json
  const channel = recordValue(recordValue(payload?.data)?.channel)
  const orders = firstString(channel ?? {}, ['standing_orders'])?.trim()
  return orders ? orders : undefined
}

function unrepliedCountFromPayload(turnStart: TurnStart): number {
  return arrayPath(turnStart.actor_event.payload_json, ['data', 'unreplied_messages']).length
}

export type TranscriptMessage = {
  index: number
  key: string
  sourceEntryID?: string
  role: 'agent' | 'human'
  sortTime: number
  speaker: string
  text: string
  time: string
}

function transcriptMessage(
  value: unknown,
  index: number,
  timezone: string,
  currentDate: string | undefined
): TranscriptMessage | undefined {
  if (!isRecord(value)) return undefined

  const text = firstString(value, ['text', 'fallback_visible_text', 'content'])
  if (!text) return undefined

  const sentAt = firstString(value, ['sent_at', 'provider_time', 'time'])
  const parsedTime = sentAt ? new Date(sentAt) : undefined
  const sortTime = parsedTime && !Number.isNaN(parsedTime.getTime()) ? parsedTime.getTime() : Number.MAX_SAFE_INTEGER
  const sourceEntryID = firstString(value, ['source_entry_id'])

  return {
    index,
    key: transcriptMessageKey(value, index),
    ...(sourceEntryID ? { sourceEntryID } : {}),
    role: transcriptRole(value),
    sortTime,
    speaker: firstString(value, ['speaker', 'display_name', 'name']) ?? speakerFromAuthor(value) ?? 'Unknown',
    text,
    time: sentAt ? formatTranscriptTime(sentAt, timezone, currentDate) : 'time unknown'
  }
}

function transcriptMessageKey(value: JSONObject, index: number): string {
  const channelID = firstString(value, ['signal_channel_id'])
  const entryID = firstString(value, ['source_entry_id'])
  if (channelID && entryID) return `${channelID}:${entryID}`
  return firstString(value, ['id']) ?? `message:${index}`
}

function transcriptRole(value: JSONObject): 'agent' | 'human' {
  return stringArg(value, 'role') === 'agent' ? 'agent' : 'human'
}

function speakerFromAuthor(value: JSONObject): string | undefined {
  if (!isRecord(value.author)) return undefined
  return firstString(value.author, ['display_name', 'name', 'principal_uid'])
}

function dedupeTranscriptMessages(messages: TranscriptMessage[]): TranscriptMessage[] {
  const byKey = new Map<string, TranscriptMessage>()
  for (const message of messages) byKey.set(message.key, message)
  return [...byKey.values()]
}

function transcriptLine(message: TranscriptMessage): string {
  return `- ${message.time} [${message.role}] ${message.speaker}: ${message.text}`
}

// Only human rows carry an id tag: they are the only valid asked_by targets.
function deltaTranscriptLine(message: TranscriptMessage): string {
  if (message.role !== 'human' || !message.sourceEntryID) return transcriptLine(message)
  return `- [id:${message.sourceEntryID}] ${message.time} [${message.role}] ${message.speaker}: ${message.text}`
}

function formatTranscriptTime(value: string, timezone: string, currentDate: string | undefined): string {
  const parts = zonedDateTimeParts(value, timezone)
  if (!parts) return value

  const date = `${parts.year}-${parts.month}-${parts.day}`
  const time = `${parts.hour}:${parts.minute}`
  return date === currentDate ? time : `${date} ${time}`
}

/**
 * Parses the recognizer's structured JSON decision.
 */
function parseAmbientDecision(text: string): { intervene: boolean; reason: string; askedBy?: string } {
  const parsed = parseJSONObject(text)
  const askedBy = stringArg(parsed, 'asked_by')
  return {
    intervene: parsed.should_proactively_speak === true,
    reason: stringArg(parsed, 'reason') ?? '',
    ...(askedBy ? { askedBy } : {})
  }
}

/**
 * Recovers a JSON object from model output that may contain extra text despite
 * the structured-output request.
 */
function parseJSONObject(text: string): JSONObject {
  const trimmed = text.trim()
  if (!trimmed) return {}

  const parsed = parseJSONRecord(trimmed)
  if (parsed) return parsed

  const start = trimmed.indexOf('{')
  const end = trimmed.lastIndexOf('}')
  if (start >= 0 && end > start) {
    return parseJSONRecord(trimmed.slice(start, end + 1)) ?? { reason: safeJSONStringify({ invalid_json: trimmed }) }
  }
  return { reason: safeJSONStringify({ invalid_json: trimmed }) }
}

function parseJSONRecord(text: string): JSONObject | undefined {
  const parsed = safeJSONParse(text)
  return parsed.match({
    ok: value => recordValue(value) ?? {},
    err: () => undefined
  })
}
