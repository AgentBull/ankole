import type { ActorInputEnvelope, JsonObject } from '../../actor_lane'
import type { AgentMessage } from '../types'
import type { Message, Model } from '../../ai-gateway-client/ankole'
import {
  prependEnvironmentInfoLinesToUserMessage,
  prependPreviousChatHistoryToUserMessage,
  renderMessageWithContext
} from './message_context'
import type { AgentConversationContext, ConversationHistoryMessage, ConversationHistoryResponse } from '../../rpc_lane'
import { COMPRESSION_KEEP_RECENT_TOKENS, PROMPT_SEND_AT_GAP_MS } from './turn_config'
import { assistantMessage, estimateCompressionTokens, storedContentText, userMessage } from './turn_messages'
import { deepString, isRecord, parseTimeMs, recordArg } from '../../common/json-utils'

export type ConversationContext = {
  messages: AgentMessage[]
  compressibleMessages: CompressibleConversationMessage[]
  materializedInputIds: Set<string>
  pendingUserEnvironmentInfoLines: string[]
  previousChatHistorySummaries: string[]
}

type CompressibleConversationMessage = {
  id: string
  message: AgentMessage
}

export function conversationContextFromHistory(
  history: ConversationHistoryResponse,
  model: Model | undefined,
  context: AgentConversationContext,
  opts: { excludeActorInputIds?: Set<string> } = {}
): ConversationContext {
  const materializedInputIds = new Set<string>()
  const messages: AgentMessage[] = []
  const compressibleMessages: CompressibleConversationMessage[] = []
  const pendingUserEnvironmentInfoLines: string[] = []
  const previousChatHistorySummaries: string[] = []
  const coveredBySummaries = summaryCoveredMessageIds(history.messages ?? [])
  let lastInjectedSendAtMs: number | undefined

  for (const row of history.messages ?? []) {
    const metadata = isRecord(row.metadata) ? (row.metadata as JsonObject) : {}
    const actorInputId = deepString(metadata, ['actor_input_id'])
    if (actorInputId) materializedInputIds.add(actorInputId)
    if (actorInputId && opts.excludeActorInputIds?.has(actorInputId)) continue

    const kind = typeof row.kind === 'string' ? row.kind : 'normal'
    const text = storedContentText(row.content)
    if (!text) continue

    if (kind === 'summary') {
      previousChatHistorySummaries.push(text)
      continue
    }
    if (typeof row.id === 'string' && coveredBySummaries.has(row.id)) continue
    if (kind === 'introspection' && row.role !== 'im_ambient') {
      pendingUserEnvironmentInfoLines.push(runtimeNoteEnvironmentInfoLine(text))
      continue
    }

    const sendAtMs = parseTimeMs(row.created_at ?? undefined)
    const injectSendAt =
      shouldConsiderPromptSendAt(row) &&
      row.created_at !== null &&
      row.created_at !== undefined &&
      sendAtMs !== undefined &&
      (lastInjectedSendAtMs === undefined || sendAtMs - lastInjectedSendAtMs > PROMPT_SEND_AT_GAP_MS)
    if (injectSendAt) lastInjectedSendAtMs = sendAtMs

    const message = storedConversationMessage(
      {
        role: row.role,
        kind,
        content: row.content,
        metadata: promptMetadata(metadata, row.created_at ?? undefined, context, injectSendAt)
      },
      text,
      model
    )
    if (message) {
      messages.push(message)
      if (typeof row.id === 'string' && kind !== 'introspection') {
        compressibleMessages.push({ id: row.id, message })
      }
    }
  }

  return {
    messages,
    compressibleMessages,
    materializedInputIds,
    pendingUserEnvironmentInfoLines,
    previousChatHistorySummaries
  }
}

export function selectCompressionPrefix(
  entries: CompressibleConversationMessage[]
): { messages: AgentMessage[]; coveredMessageIds: string[] } | undefined {
  if (entries.length === 0) return undefined

  let keptTokens = 0
  let firstKeptIndex = entries.length

  for (let index = entries.length - 1; index >= 0; index -= 1) {
    keptTokens += estimateCompressionTokens(entries[index]!.message)
    firstKeptIndex = index
    if (keptTokens >= COMPRESSION_KEEP_RECENT_TOKENS) break
  }

  while (firstKeptIndex < entries.length && entries[firstKeptIndex]?.message.role === 'toolResult') {
    firstKeptIndex += 1
  }

  if (firstKeptIndex <= 0) return undefined

  const prefix = entries.slice(0, firstKeptIndex)
  if (prefix.length === 0) return undefined

  return {
    messages: prefix.map(entry => entry.message),
    coveredMessageIds: prefix.map(entry => entry.id)
  }
}

export function inputAlreadyMaterialized(input: ActorInputEnvelope, conversation: ConversationContext): boolean {
  return (
    conversation.materializedInputIds.has(input.actor_input_id) ||
    Boolean(deepString(input.payload_json, ['data', 'internal', 'trigger_message_id']))
  )
}

export function attachPendingEnvironmentInfoToUserMessage(
  messages: AgentMessage[],
  prompts: Message[],
  lines: string[]
): { messages: AgentMessage[]; prompts: Message[] } {
  const environmentInfoLines = lines.filter(line => line.trim().length > 0)
  if (environmentInfoLines.length === 0) return { messages, prompts }

  const promptIndex = prompts.findIndex(message => message.role === 'user')
  if (promptIndex >= 0) {
    const nextPrompts = [...prompts]
    nextPrompts[promptIndex] = prependEnvironmentInfoLinesToUserMessage(
      nextPrompts[promptIndex]!,
      environmentInfoLines
    ) as Message
    return { messages, prompts: nextPrompts }
  }

  for (let index = messages.length - 1; index >= 0; index -= 1) {
    if (messages[index]?.role !== 'user') continue
    const nextMessages = [...messages]
    nextMessages[index] = prependEnvironmentInfoLinesToUserMessage(nextMessages[index]!, environmentInfoLines)
    return { messages: nextMessages, prompts }
  }

  return {
    messages,
    prompts: [prependEnvironmentInfoLinesToUserMessage(userMessage(''), environmentInfoLines) as Message, ...prompts]
  }
}

export function attachPreviousChatHistoryToUserMessage(
  messages: AgentMessage[],
  prompts: Message[],
  history: string | undefined
): { messages: AgentMessage[]; prompts: Message[] } {
  const previousHistory = history?.trim()
  if (!previousHistory) return { messages, prompts }

  const promptIndex = prompts.findIndex(message => message.role === 'user')
  if (promptIndex >= 0) {
    const nextPrompts = [...prompts]
    nextPrompts[promptIndex] = prependPreviousChatHistoryToUserMessage(
      nextPrompts[promptIndex]!,
      previousHistory
    ) as Message
    return { messages, prompts: nextPrompts }
  }

  for (let index = messages.length - 1; index >= 0; index -= 1) {
    if (messages[index]?.role !== 'user') continue
    const nextMessages = [...messages]
    nextMessages[index] = prependPreviousChatHistoryToUserMessage(nextMessages[index]!, previousHistory)
    return { messages: nextMessages, prompts }
  }

  return {
    messages,
    prompts: [prependPreviousChatHistoryToUserMessage(userMessage(''), previousHistory) as Message, ...prompts]
  }
}

function summaryCoveredMessageIds(rows: ConversationHistoryMessage[]): Set<string> {
  const ids = new Set<string>()
  for (const row of rows) {
    if (row.kind !== 'summary') continue
    const coversRange = isRecord(row.covers_range) ? row.covers_range : {}
    const messageIds = Array.isArray(coversRange.message_ids) ? coversRange.message_ids : []
    for (const id of messageIds) {
      if (typeof id === 'string' && id.trim()) ids.add(id)
    }
  }
  return ids
}

function shouldConsiderPromptSendAt(row: ConversationHistoryMessage): boolean {
  return row.role === 'user' || row.role === 'im_ambient'
}

function promptMetadata(
  metadata: JsonObject,
  sendAt: string | undefined,
  context: AgentConversationContext,
  injectSendAt: boolean
): JsonObject {
  const messageContext = recordArg(metadata, 'message_context') ?? {}
  const oldTime = recordArg(messageContext, 'time') ?? {}
  const time =
    injectSendAt && sendAt
      ? {
          ...oldTime,
          injected: true,
          send_at: sendAt,
          timezone: context.conversation?.timezone || undefined
        }
      : {
          ...oldTime,
          injected: false
        }

  return {
    ...metadata,
    message_context: {
      ...messageContext,
      time
    }
  }
}

function storedConversationMessage(line: JsonObject, text: string, model: Model | undefined): AgentMessage | undefined {
  const role = typeof line.role === 'string' ? line.role : 'user'
  if (role === 'assistant') {
    return assistantMessage(model, text)
  }
  if (role === 'im_ambient' && line.kind !== 'introspection') {
    return undefined
  }
  return renderMessageWithContext(userMessage(text), recordArg(line, 'metadata') ?? {})
}

function runtimeNoteEnvironmentInfoLine(text: string): string {
  return `runtime_note: ${text.replace(/\s+/g, ' ').trim()}`
}
