import type { AgentMessage } from '../core'
import type { TextContent } from '../llm'
import type { JsonObject } from '../actor_lane'

const MESSAGE_CONTEXT_METADATA_KEY = 'message_context'

/**
 * Prepends persisted Ankole `<message_context>` metadata to the first user text
 * block. The sparse-injection decisions were frozen when the control plane wrote
 * the message; this renderer only projects those decisions into the model view.
 */
export function renderMessageWithContext(message: AgentMessage, metadata: JsonObject): AgentMessage {
  if (message.role !== 'user') return message
  const prefix = renderMessageContextPrefix(metadata)
  if (!prefix) return message

  if (typeof message.content === 'string') {
    return { ...message, content: `${prefix}\n\n${message.content}` }
  }

  const content = [...message.content]
  const firstTextIndex = content.findIndex(block => block.type === 'text')
  if (firstTextIndex < 0) {
    return { ...message, content: [{ type: 'text', text: prefix }, ...content] }
  }

  const firstText = content[firstTextIndex] as TextContent
  content[firstTextIndex] = { ...firstText, text: `${prefix}\n\n${firstText.text}` }
  return { ...message, content }
}

/**
 * Renders the context lines whose persisted `injected` flag is true. Returning
 * undefined means this message should remain unprefixed.
 */
export function renderMessageContextPrefix(metadata: JsonObject): string | undefined {
  const context = objectValue(metadata[MESSAGE_CONTEXT_METADATA_KEY])
  const lines: string[] = []

  const time = objectValue(context.time)
  if (time.injected === true && typeof time.sent_at === 'string') {
    lines.push(`sent_at: ${formatTimestamp(time.sent_at, stringValue(time.timezone))}`)
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

  return lines.length > 0 ? `<message_context>\n${lines.join('\n')}\n</message_context>` : undefined
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
