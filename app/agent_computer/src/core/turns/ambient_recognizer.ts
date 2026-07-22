import {
  arrayPath,
  firstString,
  isRecord,
  recordValue,
  safeJsonParse as safeJSONParse,
  safeJsonStringify as safeJSONStringify,
  stringArg,
  type JsonObject as JSONObject
} from '@pleisto/active-support'
import type { TurnStart } from '../../lanes/actor_lane'
import { buildAmbientRecognizerSystemPrompt, buildAmbientRecognizerUserPrompt } from '../../prompts/ambient_prompt'
import { currentChannelFromTurnStart } from './actor_event_text'
import { assistantText, callModel, type Message, type ModelConfig, userMessage } from '../llm'
import type { AgentConversationContextResponse } from '../../lanes/rpc_lane'

export interface AmbientRecognizerInput {
  turnStart: TurnStart
  model: ModelConfig
  historyMessages: unknown[]
  agentConversationContext: AgentConversationContextResponse
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
  opts?: { abortSignal?: AbortSignal; currentTime?: Date }
): Promise<AmbientRecognizerResult> {
  const turnStart = input.turnStart
  const context = input.agentConversationContext
  const currentChannel = currentChannelFromTurnStart(turnStart)
  const timezone = context.conversation?.timezone ?? 'UTC'
  const displayName = context.agent?.displayName ?? turnStart.turn.actor.agent_uid
  const currentTime = (opts?.currentTime ?? new Date()).toISOString()
  const conversationHistory = ambientConversationHistory(input, timezone, currentTime)

  const result = await callModel(input.model, {
    instructions: buildAmbientRecognizerSystemPrompt({
      displayName,
      mission: context.mission,
      soul: context.soul ?? ''
    }),
    messages: [
      userMessage(
        buildAmbientRecognizerUserPrompt({
          brainSnapshot: context.brainSnapshot,
          conversationHistory,
          currentTime: formatZonedDateTime(currentTime, timezone),
          groupName: currentChannel?.name,
          platform: currentChannel?.platform,
          timezone
        })
      )
    ],
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
          'Use the group conversation from this ambient turn as the task and write the visible group reply now.'
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
        reason: {
          type: 'string',
          description: 'One sentence explaining why the agent should or should not speak now.'
        },
        should_proactively_speak: {
          type: 'boolean',
          description: 'True when the agent should proactively speak in the group; false when it should stay silent.'
        }
      },
      required: ['reason', 'should_proactively_speak'],
      additionalProperties: false
    }
  }
} as const

function ambientConversationHistory(input: AmbientRecognizerInput, timezone: string, currentTime: string): string {
  const payload = input.turnStart.actor_event.payload_json
  const currentDate = formatZonedDate(currentTime, timezone)
  const rawMessages = [
    ...arrayPath(payload, ['data', 'channel_context', 'messages']),
    ...arrayPath(payload, ['data', 'unreplied_messages']),
    ...arrayPath(payload, ['data', 'observed_messages'])
  ]
  const visibleMessages = rawMessages.length > 0 ? rawMessages : input.historyMessages

  const messages = visibleMessages
    .map((value, index) => transcriptMessage(value, index, timezone, currentDate))
    .filter((message): message is TranscriptMessage => message !== undefined)

  return dedupeTranscriptMessages(messages)
    .sort((a, b) => a.sortTime - b.sortTime || a.index - b.index)
    .map(transcriptLine)
    .join('\n')
}

type TranscriptMessage = {
  index: number
  key: string
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

  return {
    index,
    key: transcriptMessageKey(value, index),
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

function formatZonedDateTime(value: string, timezone: string): string {
  const parts = zonedDateTimeParts(value, timezone)
  return parts ? `${parts.year}-${parts.month}-${parts.day} ${parts.hour}:${parts.minute}` : value
}

function formatZonedDate(value: string, timezone: string): string | undefined {
  const parts = zonedDateTimeParts(value, timezone)
  return parts ? `${parts.year}-${parts.month}-${parts.day}` : undefined
}

function formatTranscriptTime(value: string, timezone: string, currentDate: string | undefined): string {
  const parts = zonedDateTimeParts(value, timezone)
  if (!parts) return value

  const date = `${parts.year}-${parts.month}-${parts.day}`
  const time = `${parts.hour}:${parts.minute}`
  return date === currentDate ? time : `${date} ${time}`
}

function zonedDateTimeParts(
  value: string,
  timezone: string
): { day: string; hour: string; minute: string; month: string; year: string } | undefined {
  const date = new Date(value)
  if (Number.isNaN(date.getTime())) return undefined

  try {
    const parts = new Intl.DateTimeFormat('en-CA', {
      timeZone: timezone,
      year: 'numeric',
      month: '2-digit',
      day: '2-digit',
      hour: '2-digit',
      minute: '2-digit',
      hourCycle: 'h23'
    }).formatToParts(date)

    const part = (type: string) => parts.find(item => item.type === type)?.value ?? '00'
    return {
      day: part('day'),
      hour: part('hour'),
      minute: part('minute'),
      month: part('month'),
      year: part('year')
    }
  } catch {
    return undefined
  }
}

/**
 * Parses the recognizer's structured JSON decision.
 */
function parseAmbientDecision(text: string): { intervene: boolean; reason: string } {
  const parsed = parseJSONObject(text)
  return {
    intervene: parsed.should_proactively_speak === true,
    reason: stringArg(parsed, 'reason') ?? ''
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
  return parsed.match(
    value => recordValue(value) ?? {},
    () => undefined
  )
}
