import { stringify as stringifyYaml } from 'yaml'
import { z } from 'zod/v4'
import type { TurnStart, JsonObject } from '../actor_lane'
import { generateText, Output, zodSchema, type Message, type Model } from '../llm'
import { convertBullXMessagesToModelMessages } from '../llm/bullx-ai-sdk'
import type { ProviderOptions } from '../llm/provider-utils'
import { buildAmbientRecognizerSystemPrompt, buildAmbientRecognizerUserPrompt } from '../prompts/ambient_prompt'
import type { AgentProfile, RuntimeConversationMessage, TurnRuntimeContext } from '../rpc_lane'

type ConversationRow = {
  id: string
  role: string
  kind: string
  content: unknown
  metadata: JsonObject
  inserted_at?: string
}

type SceneMessage = {
  id: string
  role: string
  kind: string
  speaker: string
  sent_at: string
  text: string
  provider_entry_id?: string
  signal_channel_id?: string
  source?: string
}

type AmbientRecognizerResult = {
  intervene: boolean
  reason?: string
}

const AmbientRecognizerDecisionSchema = z
  .object({
    intervene: z.boolean(),
    reason: z.string()
  })
  .strict()

export type AmbientRecognition = {
  decision: AmbientRecognizerResult
  intervention?: {
    text: string
    metadata: JsonObject
    proposedMessage: {
      role: 'im_ambient'
      content_json: Array<{ type: 'text'; text: string }>
      metadata_json: JsonObject
    }
  }
}

const MAX_CHAT_SEGMENT_TEXT = 2_000
const MAX_RECOGNIZER_CONTEXT_ROWS = 10
const COMPACT_TIME_GAP_MS = 5 * 60 * 1000

/**
 * Runs the light-model ambient recognizer inside Agent Computer. ZMQ delivers
 * the ambient event batch; this function owns the internal decision and, on a
 * yes, prepares the runtime introspection message that the same worker turn
 * will include in its final proposal.
 */
export async function runAmbientRecognizer(input: {
  headers: Record<string, string>
  model: Model
  providerOptions?: ProviderOptions
  agentProfile?: AgentProfile
  runtimeContext?: TurnRuntimeContext
  turnStart: TurnStart
  workspaceRoot: string
}): Promise<AmbientRecognition> {
  if (!input.model.sdkModel) {
    throw new Error(`LLM model ${input.model.provider}/${input.model.id} is missing an AI SDK model instance`)
  }

  const rows = loadConversationRows(input.workspaceRoot, input.turnStart, input.runtimeContext)
  const currentBatch = currentAmbientBatch(rows, input.turnStart)
  if (currentBatch.length === 0) {
    return {
      decision: { intervene: false, reason: 'No pending ambient messages.' }
    }
  }

  const currentScene = currentObservedScene(input.turnStart, currentBatch)
  const firstCurrentIndex = rows.indexOf(currentBatch[0]!)
  const lastInterventionIndex = latestInterventionIndex(rows, firstCurrentIndex)
  const recentSceneTranscript = rows
    .slice(Math.max(0, firstCurrentIndex - MAX_RECOGNIZER_CONTEXT_ROWS), firstCurrentIndex)
    .filter(row => row.role === 'user' || row.role === 'assistant' || isAmbientIntervention(row))
    .slice(-MAX_RECOGNIZER_CONTEXT_ROWS)
  const ambientRecall = rows
    .slice(Math.max(0, lastInterventionIndex + 1), firstCurrentIndex)
    .filter(row => row.role === 'im_ambient' && row.kind === 'normal')
    .slice(-MAX_RECOGNIZER_CONTEXT_ROWS)

  const displayName = agentDisplayName(input.turnStart, input.agentProfile)
  const timezone = batchTimezone(currentBatch) ?? 'UTC'
  const channelContext = ambientChannelContext(currentBatch)
  const decisionInput = stringifyYaml(
    {
      decision_task: 'decide_if_agent_should_visibly_reply_now',
      agent: {
        display_name: displayName,
        uid: input.turnStart.turn.actor.agent_uid
      },
      runtime_context: rejectUndefined({
        channel: channelContext,
        conversation_id: input.turnStart.turn.actor.session_id,
        timezone
      }),
      current_observed_messages: scenePromptRecords(currentScene, 'observed_room_message'),
      recent_visible_transcript: recentSceneTranscript.map(row => promptRecord(row)),
      earlier_observed_messages_since_last_reply: ambientRecall.map(row => promptRecord(row, 'observed_human'))
    },
    { lineWidth: 0 }
  ).trim()

  const systemPrompt = buildAmbientRecognizerSystemPrompt({
    agentUid: input.turnStart.turn.actor.agent_uid,
    channelLabel: stringPath(channelContext, ['label']),
    conversationId: input.turnStart.turn.actor.session_id,
    displayName,
    mission: input.runtimeContext?.mission || '',
    soul: input.runtimeContext?.soul || fallbackSoul(),
    timezone
  })
  const messages: Message[] = [
    {
      role: 'user',
      timestamp: Date.now(),
      content: [{ type: 'text', text: buildAmbientRecognizerUserPrompt(decisionInput) }]
    }
  ]
  const response = await generateText({
    model: input.model.sdkModel,
    system: systemPrompt,
    messages: convertBullXMessagesToModelMessages(messages),
    output: Output.object({
      schema: zodSchema(AmbientRecognizerDecisionSchema),
      name: 'ambient_intervention_decision',
      description: 'Decision on whether the agent should proactively speak in the observed IM room.'
    }),
    headers: input.headers,
    providerOptions: input.providerOptions,
    maxOutputTokens: 512,
    maxRetries: 2
  })

  const decision = normalizeAmbientRecognizerDecision(response.output)
  return {
    decision,
    ...(decision.intervene
      ? {
          intervention: ambientIntervention(
            input.turnStart,
            currentBatch,
            currentScene,
            decision,
            displayName,
            timezone
          )
        }
      : {})
  }
}

function normalizeAmbientRecognizerDecision(
  value: z.infer<typeof AmbientRecognizerDecisionSchema>
): AmbientRecognizerResult {
  return {
    intervene: value.intervene,
    reason: stringDecisionValue(value.reason) ?? ''
  }
}

function agentDisplayName(turnStart: TurnStart, agentProfile?: AgentProfile): string {
  const displayName = agentProfile?.display_name?.trim()
  return displayName || turnStart.turn.actor.agent_uid
}

function loadConversationRows(
  _workspaceRoot: string,
  _turnStart: TurnStart,
  runtimeContext?: TurnRuntimeContext
): ConversationRow[] {
  if (runtimeContext?.conversation?.messages) {
    return runtimeContext.conversation.messages.map(conversationRowFromRuntime)
  }

  throw new Error('ambient recognizer requires RuntimeFabric conversation context')
}

function conversationRowFromRuntime(row: RuntimeConversationMessage): ConversationRow {
  return {
    id: row.id ?? '',
    role: row.role ?? 'user',
    kind: row.kind ?? 'normal',
    content: row.content,
    metadata: isRecord(row.metadata) ? row.metadata : {},
    inserted_at: row.inserted_at ?? undefined
  }
}

function currentAmbientBatch(rows: ConversationRow[], turnStart: TurnStart): ConversationRow[] {
  const inputIds = new Set(turnStart.inputs.map(input => input.actor_input_id))
  const materialized = rows.filter(row => {
    return (
      row.role === 'im_ambient' &&
      row.kind === 'normal' &&
      inputIds.has(stringPath(row.metadata, ['actor_input_id']) ?? '')
    )
  })
  return materialized.length > 0 ? materialized : currentAmbientBatchFromInputs(turnStart)
}

/**
 * Rebuilds the current ambient batch from the merged ActorInput when the worker
 * has not materialized transcript rows yet. The durable event payload remains
 * the source of truth for the observed room; transcript rows are only historical
 * context for the recognizer.
 */
function currentAmbientBatchFromInputs(turnStart: TurnStart): ConversationRow[] {
  return turnStart.inputs
    .filter(input => input.type === 'im.message.may_intervene')
    .flatMap(input => {
      const data = objectPath(input.payload_json, ['data'])
      const entries = Array.isArray(data.entries) ? data.entries : [data.entry]

      return entries.flatMap((entry, index) => {
        if (!isRecord(entry)) return []
        const text = stringPath(entry, ['text'])
        const sentAt =
          stringPath(entry, ['sent_at']) ??
          stringPath(entry, ['provider_time']) ??
          stringPath(entry, ['time']) ??
          stringPath(input.payload_json, ['time'])
        if (!text || !sentAt) return []

        const providerEntryId = stringPath(entry, ['provider_entry_id']) ?? input.provider_entry_id
        const signalChannelId =
          stringPath(entry, ['signal_channel_id']) ?? stringPath(input.payload_json, ['signal_channel_id'])
        const providerThreadId =
          stringPath(entry, ['provider_thread_id']) ?? stringPath(input.payload_json, ['provider_thread_id'])
        const speaker =
          stringPath(entry, ['author', 'display_name']) ??
          stringPath(entry, ['author', 'name']) ??
          stringPath(input.payload_json, ['data', 'entry', 'author', 'display_name'])

        return [
          {
            id: `actor_input:${input.actor_input_id}:${providerEntryId ?? index}`,
            role: 'im_ambient',
            kind: 'normal',
            content: [{ type: 'text', text }],
            metadata: rejectUndefined({
              actor_input_id: input.actor_input_id,
              signal_channel_id: signalChannelId,
              provider_thread_id: providerThreadId,
              provider_entry_id: providerEntryId,
              message_context: rejectUndefined({
                time: rejectUndefined({
                  sent_at: sentAt,
                  timezone: stringPath(input.payload_json, ['data', 'entry', 'timezone'])
                }),
                actor: speaker ? { display_name: speaker } : undefined,
                room: rejectUndefined({
                  id: signalChannelId,
                  label: stringPath(input.payload_json, ['data', 'channel', 'label'])
                })
              })
            }),
            inserted_at: sentAt
          } satisfies ConversationRow
        ]
      })
    })
}

/**
 * Reads the room-scene snapshot produced while SignalsGateway merged the
 * ambient micro-batch. The worker deliberately does not run its own DB recall:
 * the event payload is the durable boundary between gateway observation and
 * Agent Computer recognition.
 */
function currentObservedScene(turnStart: TurnStart, currentBatch: ConversationRow[]): SceneMessage[] {
  const observed = ambientPayloadObservedMessages(turnStart)
  const rows = observed.length > 0 ? observed : currentBatch.map(conversationSceneMessage)

  return dedupeSceneMessages(rows).sort((left, right) => {
    return (parseTimeMs(left.sent_at) ?? 0) - (parseTimeMs(right.sent_at) ?? 0)
  })
}

function ambientPayloadObservedMessages(turnStart: TurnStart): SceneMessage[] {
  return turnStart.inputs.flatMap(input => {
    const observed = objectPath(input.payload_json, ['data'])
    const messages = Array.isArray(observed.observed_messages) ? observed.observed_messages : []
    return messages.flatMap((message, index) => payloadSceneMessage(message, input.actor_input_id, index))
  })
}

function payloadSceneMessage(value: unknown, actorInputId: string, index: number): SceneMessage[] {
  if (!isRecord(value)) return []
  const text = stringPath(value, ['text'])?.trim()
  const sentAt = stringPath(value, ['sent_at'])
  if (!text || !sentAt) return []

  return [
    {
      id: stringPath(value, ['id']) ?? `payload:${actorInputId}:${index}`,
      role: stringPath(value, ['role']) ?? 'channel_message',
      kind: stringPath(value, ['kind']) ?? 'normal',
      speaker: stringPath(value, ['speaker']) ?? 'unknown speaker',
      sent_at: sentAt,
      text: text.slice(0, MAX_CHAT_SEGMENT_TEXT),
      provider_entry_id: stringPath(value, ['provider_entry_id']),
      signal_channel_id: stringPath(value, ['signal_channel_id']),
      source: stringPath(value, ['source'])
    }
  ]
}

function conversationSceneMessage(row: ConversationRow): SceneMessage {
  return {
    id: `conversation:${row.id}`,
    role: promptRole(row),
    kind: row.kind,
    speaker: promptSpeaker(row),
    sent_at: chatMessageSentAt(row),
    text: messageText(row),
    provider_entry_id: stringPath(row.metadata, ['provider_refs', 'provider_message_id']),
    signal_channel_id: rowSignalChannelId(row)
  }
}

function dedupeSceneMessages(rows: SceneMessage[]): SceneMessage[] {
  const seen = new Set<string>()
  const result: SceneMessage[] = []
  for (const row of rows) {
    const key = row.provider_entry_id ? `${row.signal_channel_id ?? ''}:${row.provider_entry_id}` : row.id
    if (seen.has(key) || !row.text) continue
    seen.add(key)
    result.push(row)
  }
  return result
}

function scenePromptRecords(rows: SceneMessage[], role?: string): JsonObject[] {
  return rows.map((row, index) => scenePromptRecord(row, role, compactTimeLabel(row, index, rows)))
}

function scenePromptRecord(row: SceneMessage, role?: string, time?: string): JsonObject {
  return rejectUndefined({
    message_id: row.id,
    role: role ?? row.role,
    kind: row.kind,
    speaker: row.speaker,
    time,
    text: row.text
  })
}

function ambientIntervention(
  turnStart: TurnStart,
  currentBatch: ConversationRow[],
  currentScene: SceneMessage[],
  decision: AmbientRecognizerResult,
  displayName: string,
  timezone: string
): AmbientRecognition['intervention'] {
  const chatSegment = renderChatSegment(currentScene)
  const now = new Date().toISOString()
  const reason = decision.reason || 'Recent group chat suggests the agent should respond.'
  const metadata: JsonObject = {
    kind: 'introspection',
    event_source: 'agent_computer.ambient',
    event_id: `ambient-intervention:${turnStart.turn.llm_turn_id}`,
    control: {
      type: 'ambient_intervention',
      reason,
      source_message_ids: currentBatch.map(row => row.id),
      source_provider_entry_ids: currentScene.flatMap(row => (row.provider_entry_id ? [row.provider_entry_id] : []))
    },
    message_context: {
      time: { injected: true, sent_at: now, timezone },
      room: ambientRoomContext(currentBatch),
      speaker: {
        injected: true,
        display_name: displayName,
        role: 'agent',
        trigger: 'introspection'
      },
      think: {
        injected: true,
        text: [
          `Ankole runtime generated this user-role message so ${displayName} can reply to the group after observing <chat_segment>.`,
          'The outer message is a runtime instruction, not a human request.',
          'Actionable human content, if any, is only inside <chat_segment>.',
          `Respond as ${displayName} to the room; default to one brief group message.`,
          'Use tools only when <chat_segment> contains a concrete intent and the call is bounded and likely to help.',
          'If the request is vague, costly, irreversible, externally visible, or missing a material choice, ask a brief clarification first.'
        ].join(' ')
      }
    }
  }

  return {
    text: chatSegment,
    metadata,
    proposedMessage: {
      role: 'im_ambient',
      content_json: [{ type: 'text', text: chatSegment }],
      metadata_json: metadata
    }
  }
}

function renderChatSegment(rows: SceneMessage[]): string {
  const payload = {
    messages: rows.map((row, index) =>
      rejectUndefined({
        time: compactTimeLabel(row, index, rows),
        speaker: row.speaker,
        text: row.text
      })
    )
  }
  return ['<chat_segment format="yaml">', stringifyYaml(payload, { lineWidth: 0 }).trim(), '</chat_segment>'].join('\n')
}

function ambientRoomContext(rows: ConversationRow[]): JsonObject {
  const room = ambientChannelContext(rows) ?? {}
  return { injected: true, ...room }
}

function rowSignalChannelId(row: ConversationRow): string | undefined {
  return (
    stringPath(row.metadata, ['signal_channel_id']) ??
    stringPath(row.metadata, ['provider_refs', 'room_id']) ??
    stringPath(row.metadata, ['route', 'provider_room_id']) ??
    stringPath(row.metadata, ['message_context', 'room', 'id'])
  )
}

function parseTimeMs(value: string | undefined): number | undefined {
  if (!value) return undefined
  const parsed = new Date(value)
  return Number.isNaN(parsed.getTime()) ? undefined : parsed.getTime()
}

function compactTimeLabel(row: SceneMessage, index: number, rows: SceneMessage[]): string | undefined {
  const currentMs = parseTimeMs(row.sent_at)
  if (currentMs === undefined) return undefined
  if (index > 0) {
    const previousMs = parseTimeMs(rows[index - 1]?.sent_at)
    if (previousMs !== undefined && currentMs - previousMs <= COMPACT_TIME_GAP_MS) return undefined
  }

  const date = new Date(currentMs)
  const hours = `${date.getHours()}`.padStart(2, '0')
  const minutes = `${date.getMinutes()}`.padStart(2, '0')
  return `${hours}:${minutes}`
}

function latestInterventionIndex(rows: ConversationRow[], beforeIndex: number): number {
  for (let index = beforeIndex - 1; index >= 0; index -= 1) {
    if (isAmbientIntervention(rows[index]!)) return index
  }
  return -1
}

function isAmbientIntervention(row: ConversationRow): boolean {
  return (
    row.role === 'im_ambient' &&
    row.kind === 'introspection' &&
    stringPath(row.metadata, ['control', 'type']) === 'ambient_intervention'
  )
}

function promptRecord(row: ConversationRow, role?: string): JsonObject {
  return rejectUndefined({
    message_id: row.id,
    role: role ?? promptRole(row),
    kind: row.kind,
    speaker: promptSpeaker(row),
    sent_at: chatMessageSentAt(row),
    text: messageText(row)
  })
}

function promptRole(row: ConversationRow): string {
  if (row.role === 'assistant') return 'agent'
  if (row.role === 'tool') return 'tool'
  if (isAmbientIntervention(row)) return 'runtime'
  if (row.role === 'im_ambient') return 'ambient_human'
  return 'human'
}

function promptSpeaker(row: ConversationRow): string {
  if (row.role === 'assistant') return 'agent'
  if (row.role === 'tool') return 'tool'
  if (isAmbientIntervention(row)) return 'Ankole runtime'
  return chatMessageSpeaker(row)
}

function messageText(row: ConversationRow): string {
  if (!Array.isArray(row.content)) return ''
  return row.content
    .flatMap(block => {
      if (typeof block === 'string') return [block]
      if (isRecord(block) && typeof block.text === 'string') return [block.text]
      return []
    })
    .join('\n')
    .trim()
    .slice(0, MAX_CHAT_SEGMENT_TEXT)
}

function chatMessageSentAt(row: ConversationRow): string {
  return stringPath(row.metadata, ['message_context', 'time', 'sent_at']) ?? row.inserted_at ?? new Date().toISOString()
}

function chatMessageSpeaker(row: ConversationRow): string {
  return (
    stringPath(row.metadata, ['message_context', 'actor', 'display_name']) ??
    stringPath(row.metadata, ['actor', 'fullName']) ??
    stringPath(row.metadata, ['actor', 'userName']) ??
    stringPath(row.metadata, ['actor', 'display_name']) ??
    'unknown speaker'
  )
}

function ambientChannelContext(rows: ConversationRow[]): JsonObject | undefined {
  for (let index = rows.length - 1; index >= 0; index -= 1) {
    const room = objectPath(rows[index]!.metadata, ['message_context', 'room'])
    const label = stringPath(room, ['label'])
    const id = stringPath(room, ['id'])
    const name = stringPath(room, ['name'])
    const isDM = typeof room.is_dm === 'boolean' ? room.is_dm : undefined
    if (!label && !id && !name && isDM === undefined) continue
    return rejectUndefined({ id, is_dm: isDM, label, name })
  }
}

function batchTimezone(rows: ConversationRow[]): string | undefined {
  for (let index = rows.length - 1; index >= 0; index -= 1) {
    const timezone = stringPath(rows[index]!.metadata, ['message_context', 'time', 'timezone'])
    if (timezone) return timezone
  }
}

function stringDecisionValue(value: unknown): string | undefined {
  if (typeof value !== 'string') return undefined
  const text = value.trim()
  if (!text) return undefined
  return text.length > 240 ? `${text.slice(0, 240)}...` : text
}

function fallbackSoul(): string {
  return 'Be useful without being performative. Speak plainly, form grounded opinions, and move the work forward.'
}

function rejectUndefined(value: Record<string, unknown | undefined>): JsonObject {
  return Object.fromEntries(Object.entries(value).filter(([, item]) => item !== undefined)) as JsonObject
}

function stringPath(source: unknown, path: string[]): string | undefined {
  const value = path.reduce<unknown>((current, key) => (isRecord(current) ? current[key] : undefined), source)
  return typeof value === 'string' && value.trim().length > 0 ? value : undefined
}

function objectPath(source: unknown, path: string[]): JsonObject {
  const value = path.reduce<unknown>((current, key) => (isRecord(current) ? current[key] : undefined), source)
  return isRecord(value) ? value : {}
}

function isRecord(value: unknown): value is JsonObject {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}
