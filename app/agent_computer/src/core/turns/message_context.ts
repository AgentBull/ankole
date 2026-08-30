import { recordValue, type JsonObject as JSONObject } from '@agentbull/active-support'
import type { TurnStart } from '../../lanes/actor_lane'
import { formatZonedDateTime } from '../../prompts/zoned_time'
import type { TextContent, UserMessage } from '../llm'
import { scheduleTurnContextFromTurnStart } from './schedule_turn_context'

const AGENT_ENVIRONMENT_INFO_OPEN = '<agent_environment_info>'
const AGENT_ENVIRONMENT_INFO_CLOSE = '</agent_environment_info>'
const AGENT_ENVIRONMENT_INFO_TAG = /<\s*\/?\s*agent_environment_info\s*>/giu
const ENVIRONMENT_INFO_LINE_BREAK = /[\r\n\u2028\u2029]+/gu

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
  payload: JSONObject | undefined,
  opts: { timezone?: string | null } = {}
): string[] {
  const data = recordValue(payload?.data) ?? {}
  const entry = recordValue(data.entry) ?? {}
  const channel = recordValue(data.channel) ?? {}
  const author = recordValue(entry.author) ?? {}
  const lifecycle = recordValue(data.lifecycle) ?? {}
  const lines: string[] = []

  const sendAt = stringValue(entry.provider_time) ?? stringValue(payload?.time)
  const formattedSendAt = sendAt ? formatZonedDateTime(sendAt, opts.timezone || 'UTC') : undefined
  if (formattedSendAt) lines.push(`send_at: ${formattedSendAt}`)

  const signalChannelID = stringValue(entry.signal_channel_id) ?? stringValue(channel.id)
  if (signalChannelID) lines.push(`signal_channel_id: ${signalChannelID}`)

  if (stringValue(channel.kind) === 'im_group') {
    const speaker = speakerLabel(author)
    if (speaker) lines.push(`speaker: ${speaker}`)
  }

  const lifecycleKind = stringValue(lifecycle.kind)
  if (lifecycleKind) lines.push(`entry_lifecycle: ${lifecycleKind}`)

  return lines
}

/**
 * Projects per-turn schedule facts into the trusted current-message context.
 * The interpretation rules stay in the stable system prompt; this block carries
 * only values that can legitimately change between turns in one conversation.
 */
export function turnRequestEnvironmentInfoLines(turnStart: TurnStart): string[] {
  const context = scheduleTurnContextFromTurnStart(turnStart)
  if (!context) return []

  const origin = context.origin

  const lines = [
    `schedule_turn_mode: ${context.mode}`,
    `schedule_due_at: ${origin.dueAt ?? 'unknown'}`,
    `schedule_fired_at: ${origin.firedAt ?? 'unknown'}`,
    `schedule_timezone: ${origin.timezone ?? 'unknown'}`,
    `schedule_silent_success_allowed: ${context.silentSuccessAllowed}`
  ]

  const cronScheduleName = origin.cronScheduleName
  if (cronScheduleName) lines.push(`cron_schedule_name: ${cronScheduleName}`)

  const identicalReplies = context.consecutiveIdenticalReplies
  if (identicalReplies !== undefined) {
    lines.push(`schedule_consecutive_identical_replies: ${identicalReplies}`)
  }

  if (Object.keys(origin.payload).length > 0) lines.push(`schedule_payload: ${JSON.stringify(origin.payload)}`)

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
  const safeLines = lines.map(environmentInfoLine).filter(line => line.length > 0)
  return `${AGENT_ENVIRONMENT_INFO_OPEN}\n${safeLines.join('\n')}\n${AGENT_ENVIRONMENT_INFO_CLOSE}`
}

function environmentInfoLine(line: string): string {
  return line
    .replace(AGENT_ENVIRONMENT_INFO_TAG, tag => tag.replaceAll('<', '&lt;').replaceAll('>', '&gt;'))
    .replace(ENVIRONMENT_INFO_LINE_BREAK, ' ')
    .trim()
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
 * Chooses the best available group speaker label. A normal user needs no role
 * suffix; non-user senders keep the role because it changes how to interpret
 * the message.
 */
function speakerLabel(author: JSONObject): string | undefined {
  const uid = stringValue(author.principal_uid) ?? stringValue(author.platform_subject)
  const name = stringValue(author.display_name) ?? stringValue(author.name) ?? uid
  if (!name) return undefined

  const labeledUID = uid ? `${name}(${uid})` : name

  const senderType = stringValue((recordValue(author.metadata) ?? {}).sender_type)
  return senderType && senderType.toLowerCase() !== 'user' ? `${labeledUID} (${senderType})` : labeledUID
}

/**
 * Reads a non-empty string value.
 */
function stringValue(value: unknown): string | undefined {
  return typeof value === 'string' && value.trim().length > 0 ? value : undefined
}
