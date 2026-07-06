import { recordValue, type JsonObject } from '@pleisto/active-support'
import type { TextContent, UserMessage } from '../llm'

const AGENT_ENVIRONMENT_INFO_OPEN = '<agent_environment_info>'
const AGENT_ENVIRONMENT_INFO_CLOSE = '</agent_environment_info>'

/**
 * Prepends actor-event environment facts to a user message.
 *
 * The facts are user-message context, not system prompt content, so replay and
 * prompt caching do not treat dynamic provider metadata as stable instructions.
 */
export function prependEnvironmentInfoLinesToUserMessage(message: UserMessage, lines: string[]): UserMessage {
  const infoLines = lines.map(line => line.trim()).filter(line => line.length > 0)
  if (infoLines.length === 0) return message

  return upsertEnvironmentInfoPart(message, infoLines)
}

/**
 * Extracts a small set of provider facts that help the model interpret the
 * current actor event.
 */
export function actorEventEnvironmentInfoLines(
  payload: JsonObject | undefined,
  opts: { timezone?: string | null } = {}
): string[] {
  const data = objectValue(payload?.data)
  const entry = objectValue(data.entry)
  const channel = objectValue(data.channel)
  const author = objectValue(entry.author)
  const lifecycle = objectValue(data.lifecycle)
  const lines: string[] = []

  const sendAt = stringValue(entry.provider_time) ?? stringValue(payload?.time)
  if (sendAt) lines.push(`send_at: ${formatTimestamp(sendAt, opts.timezone ?? undefined)}`)

  const room = roomLabel(channel)
  if (room) lines.push(`room: ${room}`)

  const speaker = speakerLabel(author)
  if (speaker) lines.push(`speaker: ${speaker}`)

  const senderType = stringValue(objectValue(author.metadata).sender_type)
  if (senderType) lines.push(`speaker_role: ${senderType}`)

  const lifecycleKind = stringValue(lifecycle.kind)
  if (lifecycleKind) lines.push(`entry_lifecycle: ${lifecycleKind}`)

  return lines
}

/**
 * Inserts or merges the `<agent_environment_info>` block in a user message.
 *
 * Merge support keeps callers from accidentally creating multiple environment
 * blocks when the message already contains one from earlier processing.
 */
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

  content.unshift(part)
  return { ...message, content }
}

/**
 * Renders environment facts in a tagged block that remains plain text for the
 * provider but easy for the model to distinguish from user prose.
 */
function renderAgentEnvironmentInfoBlock(lines: string[]): string {
  return `${AGENT_ENVIRONMENT_INFO_OPEN}\n${lines.join('\n')}\n${AGENT_ENVIRONMENT_INFO_CLOSE}`
}

/**
 * Appends new environment lines to an existing tagged block.
 */
function mergeEnvironmentInfoBlock(existing: string, lines: string[]): string {
  const body = existing.trim().slice(AGENT_ENVIRONMENT_INFO_OPEN.length, -AGENT_ENVIRONMENT_INFO_CLOSE.length).trim()
  return renderAgentEnvironmentInfoBlock(body ? [...body.split('\n'), ...lines] : lines)
}

/**
 * Detects the exact environment-info block wrapper.
 */
function isAgentEnvironmentInfoBlock(text: string): boolean {
  const trimmed = text.trim()
  return trimmed.startsWith(`${AGENT_ENVIRONMENT_INFO_OPEN}\n`) && trimmed.endsWith(`\n${AGENT_ENVIRONMENT_INFO_CLOSE}`)
}

/**
 * Chooses a compact room label from channel metadata.
 */
function roomLabel(channel: JsonObject): string | undefined {
  const name = stringValue(channel.name) ?? stringValue(channel.title)
  if (name) return name

  const kind = stringValue(channel.kind)
  const id = stringValue(channel.id)
  if (kind && id) return `${kind} ${id}`
  return id ?? kind
}

/**
 * Chooses the best available speaker label from author metadata.
 */
function speakerLabel(author: JsonObject): string | undefined {
  return (
    stringValue(author.display_name) ??
    stringValue(author.name) ??
    stringValue(author.principal_uid) ??
    stringValue(author.id)
  )
}

/**
 * Formats provider timestamps in the conversation timezone when available.
 */
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

/**
 * Narrows unknown values to JSON objects, using an empty object as fallback.
 */
function objectValue(value: unknown): JsonObject {
  return recordValue(value) ?? {}
}

/**
 * Reads a non-empty string value.
 */
function stringValue(value: unknown): string | undefined {
  return typeof value === 'string' && value.trim().length > 0 ? value : undefined
}
