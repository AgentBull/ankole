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
import { z } from 'zod'
import type { TurnStart } from '../../lanes/actor_lane'
import {
  ambientActions,
  buildAmbientRecognizerSystemPrompt,
  buildAmbientRecognizerUserPrompt,
  type AmbientAction,
  type AmbientAuthority,
  type AmbientWorkCandidates
} from '../../prompts/ambient_prompt'
import { formatZonedDate, formatZonedDateTime, zonedDateTimeParts } from '../../prompts/zoned_time'
import { assistantText, callModel, type ModelConfig, userMessage } from '../llm'
import { zodToJSONSchema } from '../llm/tool-schema'
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
  action: AmbientAction
  authority: AmbientAuthority
  reason: string
  askedBy: AskedByResolution
  handoffJobID?: string
}

export interface AmbientRecognizerResult {
  decision: AmbientRecognizerDecision
}

/**
 * Routes one ambient observation without taking the selected action.
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
  const workCandidates = ambientWorkCandidates(turnStart)
  const standingOrders = standingOrdersFromPayload(turnStart)
  const decisionSchema = ambientDecisionSchema(workCandidates, {
    standingOrdersPresent: Boolean(standingOrders),
    askedByIDs: window.delta.flatMap(message =>
      message.role === 'human' && message.sourceEntryID ? [message.sourceEntryID] : []
    )
  })

  const result = await callModel(input.model, {
    instructions: buildAmbientRecognizerSystemPrompt({
      displayName,
      mission: context.mission,
      soul: context.soul ?? ''
    }),
    messages: [
      userMessage(
        buildAmbientRecognizerUserPrompt({
          standingOrders,
          backdrop: window.backdrop.map(transcriptLine),
          newMessages: window.delta.map(deltaTranscriptLine),
          workCandidates,
          currentTime: formatZonedDateTime(currentTime, timezone) ?? currentTime,
          groupName: originChannel?.label || undefined,
          adapter: originChannel?.adapter || undefined,
          timezone
        })
      )
    ],
    maxOutputTokens: 300,
    temperature: 0,
    text: ambientDecisionTextFormat(decisionSchema),
    abortSignal: opts?.abortSignal
  })

  const parsed = parseAmbientDecision(assistantText(result.message), decisionSchema)
  const acceptsAskedBy = parsed.action === 'FOREGROUND_REPLY' || parsed.action === 'NEW_WORK'
  const askedBy = acceptsAskedBy ? resolveAskedBy(parsed.askedBy, window.delta) : { state: 'none' as const }
  const authority = corroboratedAuthority(parsed, askedBy, Boolean(standingOrders))
  const decision: AmbientRecognizerDecision = {
    action: parsed.action,
    authority,
    reason:
      authority === parsed.authority
        ? parsed.reason
        : 'The proposed authorization source was not present in the current ambient observation.',
    askedBy,
    ...(parsed.handoffJobID ? { handoffJobID: parsed.handoffJobID } : {})
  }

  return { decision }
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

type AmbientDecisionWire = {
  action: AmbientAction
  authority: AmbientAuthority
  handoff_job_id: string | null
  asked_by: string | null
  reason: string
}

type AmbientDecisionEvidence = {
  standingOrdersPresent: boolean
  askedByIDs: string[]
}

function ambientDecisionSchema(
  workCandidates: AmbientWorkCandidates,
  evidence: AmbientDecisionEvidence
): z.ZodType<AmbientDecisionWire> {
  const handoffJobIDs = workCandidates.complete ? workCandidates.jobs.map(candidate => candidate.jobID) : []
  const askedByIDs = [...new Set(evidence.askedByIDs)]
  const authorities: [AmbientAuthority, ...AmbientAuthority[]] = ['NONE']
  if (askedByIDs.length > 0) authorities.push('EXPLICIT_REQUEST')
  if (evidence.standingOrdersPresent) authorities.push('STANDING_ORDER')

  return z
    .object({
      action: (handoffJobIDs.length > 0
        ? z.enum(ambientActions)
        : z.enum(['NOOP', 'FOREGROUND_REPLY', 'NEW_WORK'] as const)
      ).describe('The one host route selected for the New Messages.'),
      authority: z.enum(authorities).describe('Authorization for NEW_WORK; NONE for every other action.'),
      handoff_job_id: nullableExactID(handoffJobIDs).describe(
        handoffJobIDs.length > 0
          ? 'An exact listed Job ID for HANDOFF; null otherwise.'
          : 'HANDOFF is unavailable, so this must be null.'
      ),
      asked_by: nullableExactID(askedByIDs).describe(
        'A directly asking New Message id for a visible route; null otherwise.'
      ),
      reason: z.string().trim().min(1).max(300).describe('One short sentence explaining the selected route.')
    })
    .strict()
}

function nullableExactID(values: string[]) {
  if (values.length === 0) return z.null()
  return z.enum(values as [string, ...string[]]).nullable()
}

function ambientDecisionTextFormat(schema: z.ZodType<AmbientDecisionWire>) {
  return {
    format: {
      type: 'json_schema',
      name: 'ambient_intent_route',
      strict: true,
      schema: zodToJSONSchema(schema)
    }
  } as const
}

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
function parseAmbientDecision(
  text: string,
  schema: z.ZodType<AmbientDecisionWire>
): {
  action: AmbientAction
  authority: AmbientAuthority
  reason: string
  askedBy?: string
  handoffJobID?: string
} {
  const result = schema.safeParse(parseJSONObject(text))
  if (!result.success) return invalidAmbientDecision()

  const parsed = result.data
  const askedBy = parsed.asked_by ?? undefined
  const handoffJobID = parsed.handoff_job_id ?? undefined

  // The schema enums already fence every value set, so only the cross-field
  // rules a JSON Schema cannot express get checked here.
  if (parsed.action !== 'NEW_WORK' && parsed.authority !== 'NONE') return invalidAmbientDecision()
  if ((parsed.action === 'HANDOFF') !== Boolean(handoffJobID)) return invalidAmbientDecision()

  return {
    action: parsed.action,
    authority: parsed.authority,
    reason: parsed.reason,
    ...(askedBy ? { askedBy } : {}),
    ...(handoffJobID ? { handoffJobID } : {})
  }
}

function corroboratedAuthority(
  parsed: { action: AmbientAction; authority: AmbientAuthority },
  askedBy: AskedByResolution,
  standingOrdersPresent: boolean
): AmbientAuthority {
  if (parsed.action !== 'NEW_WORK') return parsed.authority
  if (parsed.authority === 'EXPLICIT_REQUEST' && askedBy.state === 'accepted') return parsed.authority
  if (parsed.authority === 'STANDING_ORDER' && standingOrdersPresent) return parsed.authority
  return 'NONE'
}

function invalidAmbientDecision(): {
  action: 'NOOP'
  authority: 'NONE'
  reason: string
} {
  return {
    action: 'NOOP',
    authority: 'NONE',
    reason: 'The structured ambient route was invalid, so the Agent stayed silent.'
  }
}

function ambientWorkCandidates(turnStart: TurnStart): AmbientWorkCandidates {
  const payload = recordValue(turnStart.request_context?.ambient_work_candidates)
  const handoffMessagesPresent = arrayPath(turnStart.actor_event.payload_json, ['data', 'observed_messages']).some(
    value => {
      const message = recordValue(value)
      return typeof message?.text === 'string' && message.text !== ''
    }
  )
  const jobs = arrayPath(payload, ['jobs'])
    .flatMap(value => {
      if (!isRecord(value)) return []
      const jobID = firstString(value, ['job_id'])
      const title = firstString(value, ['title'])
      const status = firstString(value, ['status'])
      if (!jobID || !title || !status) return []
      const taskExcerpt = firstString(value, ['task_excerpt'])
      return [{ jobID, title, status, ...(taskExcerpt ? { taskExcerpt } : {}) }]
    })
    .slice(0, 8)

  return { complete: payload?.complete === true && handoffMessagesPresent, jobs }
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
