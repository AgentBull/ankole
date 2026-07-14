import { recordValue, type JsonObject as JSONObject } from '@pleisto/active-support'
import type { TurnStart } from '../../lanes/actor_lane'
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
  if (sendAt) lines.push(`send_at: ${formatTimestamp(sendAt, opts.timezone ?? undefined)}`)

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
  const context = recordValue(turnStart.request_context)
  const origin = recordValue(context?.schedule_origin)
  if (!origin) return []

  const lines = [
    `schedule_turn_mode: ${stringValue(context?.turn_mode) ?? 'unknown'}`,
    `schedule_event_id: ${stringValue(origin.scheduled_event_id) ?? 'unknown'}`,
    `schedule_due_at: ${stringValue(origin.due_at) ?? 'unknown'}`,
    `schedule_fired_at: ${stringValue(origin.fired_at) ?? 'unknown'}`,
    `schedule_timezone: ${stringValue(origin.timezone) ?? 'unknown'}`,
    `schedule_silent_success_allowed: ${context?.silent_success_allowed === true}`
  ]

  const cronScheduleID = stringValue(origin.cron_schedule_id)
  const cronScheduleName = stringValue(origin.cron_schedule_name)
  if (cronScheduleID) lines.push(`cron_schedule_id: ${cronScheduleID}`)
  if (cronScheduleName) lines.push(`cron_schedule_name: ${cronScheduleName}`)

  const payload = recordValue(origin.payload)
  if (payload && Object.keys(payload).length > 0) lines.push(`schedule_payload: ${JSON.stringify(payload)}`)

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
 * Chooses the best available group speaker label. A normal user needs no role
 * suffix; non-user senders keep the role because it changes how to interpret
 * the message.
 */
function speakerLabel(author: JSONObject): string | undefined {
  const name =
    stringValue(author.display_name) ??
    stringValue(author.name) ??
    stringValue(author.principal_uid) ??
    stringValue(author.id)
  if (!name) return undefined

  const senderType = stringValue((recordValue(author.metadata) ?? {}).sender_type)
  return senderType && senderType.toLowerCase() !== 'user' ? `${name} (${senderType})` : name
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
 * Reads a non-empty string value.
 */
function stringValue(value: unknown): string | undefined {
  return typeof value === 'string' && value.trim().length > 0 ? value : undefined
}
