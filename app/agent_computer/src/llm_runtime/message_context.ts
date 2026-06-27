import type { AgentMessage } from '../core'
import type { TextContent, UserMessage } from '../llm'
import type { JsonObject } from '../actor_lane'

const MESSAGE_CONTEXT_METADATA_KEY = 'message_context'
const AGENT_ENVIRONMENT_INFO_OPEN = '<agent_environment_info>'
const AGENT_ENVIRONMENT_INFO_CLOSE = '</agent_environment_info>'
const PREVIOUS_CHAT_HISTORY_OPEN = '<previous_chat_history>'
const PREVIOUS_CHAT_HISTORY_CLOSE = '</previous_chat_history>'

/**
 * Prepends persisted Ankole `<agent_environment_info>` as its own user text
 * part. The worker decides per-prompt sparse time injection from durable
 * transcript rows; other scene facts come from message metadata.
 */
export function renderMessageWithContext(message: AgentMessage, metadata: JsonObject): AgentMessage {
  if (message.role !== 'user') return message
  const lines = renderMessageContextLines(metadata)
  return prependEnvironmentInfoLinesToUserMessage(message, lines)
}

export function prependEnvironmentInfoLinesToUserMessage(message: AgentMessage, lines: string[]): AgentMessage {
  if (message.role !== 'user') return message
  const infoLines = lines.map(line => line.trim()).filter(line => line.length > 0)
  if (infoLines.length === 0) return message

  return upsertEnvironmentInfoPart(message, infoLines)
}

export function prependPreviousChatHistoryToUserMessage(
  message: AgentMessage,
  history: string | undefined
): AgentMessage {
  if (message.role !== 'user') return message
  const previousHistory = history?.trim()
  if (!previousHistory) return message

  return prependTextPartToUserMessage(message, renderPreviousChatHistoryBlock(previousHistory))
}

/**
 * Renders the context lines whose persisted `injected` flag is true. Returning
 * undefined means this message should remain unprefixed.
 */
export function renderMessageContextPrefix(metadata: JsonObject): string | undefined {
  const lines = renderMessageContextLines(metadata)
  return lines.length > 0 ? renderAgentEnvironmentInfoBlock(lines) : undefined
}

export function renderMessageContextLines(metadata: JsonObject): string[] {
  const context = objectValue(metadata[MESSAGE_CONTEXT_METADATA_KEY])
  const lines: string[] = []

  const time = objectValue(context.time)
  const sendAt = stringValue(time.send_at) ?? stringValue(time.sent_at)
  if (time.injected === true && sendAt) {
    lines.push(`send_at: ${formatTimestamp(sendAt, stringValue(time.timezone))}`)
  }

  const room = objectValue(context.room)
  if (room.injected === true && typeof room.label === 'string') lines.push(`room: ${room.label}`)

  const speaker = objectValue(context.speaker)
  const actor = objectValue(context.actor)
  if (speaker.injected === true) {
    if (typeof speaker.display_name === 'string') lines.push(`speaker: ${speaker.display_name}`)
    if (typeof speaker.role === 'string') lines.push(`speaker_role: ${speaker.role}`)
    if (typeof speaker.trigger === 'string') lines.push(`speaker_trigger: ${speaker.trigger}`)
  } else if (actor.injected === true && typeof actor.display_name === 'string') {
    lines.push(`speaker: ${actor.display_name}`)
  }

  const think = objectValue(context.think)
  if (think.injected === true && typeof think.text === 'string') lines.push(`think: ${think.text}`)

  return lines
}

function renderAgentEnvironmentInfoBlock(lines: string[]): string {
  return `${AGENT_ENVIRONMENT_INFO_OPEN}\n${lines.join('\n')}\n${AGENT_ENVIRONMENT_INFO_CLOSE}`
}

function renderPreviousChatHistoryBlock(history: string): string {
  return `${PREVIOUS_CHAT_HISTORY_OPEN}\n${history}\n${PREVIOUS_CHAT_HISTORY_CLOSE}`
}

function prependTextPartToUserMessage(message: UserMessage, text: string): UserMessage {
  const part: TextContent = { type: 'text', text }
  if (typeof message.content === 'string') {
    return { ...message, content: [part, { type: 'text', text: message.content }] }
  }
  return { ...message, content: [part, ...message.content] }
}

function upsertEnvironmentInfoPart(message: UserMessage, lines: string[]): UserMessage {
  const part: TextContent = { type: 'text', text: renderAgentEnvironmentInfoBlock(lines) }
  if (typeof message.content === 'string') {
    return { ...message, content: [part, { type: 'text', text: message.content }] }
  }

  const content = [...message.content]
  const existingIndex = content.findIndex(block => block.type === 'text' && isAgentEnvironmentInfoBlock(block.text))
  if (existingIndex >= 0) {
    const existing = content[existingIndex] as TextContent
    content[existingIndex] = { ...existing, text: mergeEnvironmentInfoBlock(existing.text, lines) }
    return { ...message, content }
  }

  const insertIndex = content[0]?.type === 'text' && isPreviousChatHistoryBlock(content[0].text) ? 1 : 0
  content.splice(insertIndex, 0, part)
  return { ...message, content }
}

function mergeEnvironmentInfoBlock(existing: string, lines: string[]): string {
  const body = existing.trim().slice(AGENT_ENVIRONMENT_INFO_OPEN.length, -AGENT_ENVIRONMENT_INFO_CLOSE.length).trim()
  return renderAgentEnvironmentInfoBlock(body ? [...body.split('\n'), ...lines] : lines)
}

function isAgentEnvironmentInfoBlock(text: string): boolean {
  const trimmed = text.trim()
  return trimmed.startsWith(`${AGENT_ENVIRONMENT_INFO_OPEN}\n`) && trimmed.endsWith(`\n${AGENT_ENVIRONMENT_INFO_CLOSE}`)
}

function isPreviousChatHistoryBlock(text: string): boolean {
  const trimmed = text.trim()
  return trimmed.startsWith(`${PREVIOUS_CHAT_HISTORY_OPEN}\n`) && trimmed.endsWith(`\n${PREVIOUS_CHAT_HISTORY_CLOSE}`)
}

function formatTimestamp(value: string, timezone?: string): string {
  const parsed = new Date(value)
  if (Number.isNaN(parsed.getTime()) || !timezone) return value
  try {
    const parts = new Intl.DateTimeFormat('en-US', {
      timeZone: timezone,
      year: 'numeric',
      month: '2-digit',
      day: '2-digit',
      hour: '2-digit',
      minute: '2-digit',
      second: '2-digit',
      hourCycle: 'h23'
    }).formatToParts(parsed)
    const part = (type: string) => parts.find(item => item.type === type)?.value ?? '00'
    return `${part('year')}-${part('month')}-${part('day')} ${part('hour')}:${part('minute')}:${part('second')} (${timezone})`
  } catch {
    return value
  }
}

function objectValue(value: unknown): JsonObject {
  return typeof value === 'object' && value !== null && !Array.isArray(value) ? (value as JsonObject) : {}
}

function stringValue(value: unknown): string | undefined {
  return typeof value === 'string' && value.trim().length > 0 ? value : undefined
}
