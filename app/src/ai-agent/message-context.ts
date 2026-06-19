import { and, asc, eq, sql } from 'drizzle-orm'
import { ms } from '@pleisto/active-support'
import type { TextContent } from '@/llm'
import { DB, type QueryExecutor } from '@/common/database'
import { AiAgentMessages, type JsonObject } from '@/common/db-schema'
import { stringFromPath, toJsonObject } from '@/common/json'
import { zonedParts } from '@/config/system'
import type { AgentMessage } from './core'

export const MESSAGE_CONTEXT_METADATA_KEY = 'message_context'

const TIME_CONTEXT_GAP_MS = ms('1h')
const MAX_CONTEXT_LINE_TEXT = 800

export interface MessageContextInput {
  actor?: JsonObject
  room?: JsonObject
  sentAt: Date
  speaker?: string
  speakerRole?: string
  speakerTrigger?: string
  think?: string
  timezone: string
}

export interface MessageContextHistoryItem {
  metadata: JsonObject
}

export async function loadMessageContextHistory(
  conversationId: string,
  db: QueryExecutor = DB
): Promise<MessageContextHistoryItem[]> {
  const rows = await db
    .select({ metadata: AiAgentMessages.metadata })
    .from(AiAgentMessages)
    .where(
      and(
        eq(AiAgentMessages.conversationId, conversationId),
        sql`${AiAgentMessages.role} in ('user', 'im_ambient')`,
        sql`${AiAgentMessages.kind} in ('normal', 'introspection')`,
        sql`${AiAgentMessages.metadata}->'transcript_effect' is null`
      )
    )
    .orderBy(asc(AiAgentMessages.createdAt), asc(AiAgentMessages.id))

  return rows.map(row => ({ metadata: row.metadata }))
}

export function buildMessageContextMetadata(
  input: MessageContextInput,
  history: MessageContextHistoryItem[]
): JsonObject {
  const sentAt = input.sentAt
  const actor = actorContext(input.actor)
  const room = roomContext(input.room, actor.displayName)
  const context: JsonObject = {
    time: {
      sent_at: sentAt.toISOString(),
      injected: shouldInjectTime(sentAt, history),
      gap_ms: TIME_CONTEXT_GAP_MS,
      timezone: input.timezone
    }
  }

  if (room) {
    context.room = {
      id: room.id ?? null,
      is_dm: room.isDM,
      name: room.name ?? null,
      label: room.label,
      injected: shouldInjectRoom(room, history)
    }
  }

  if (actor.displayName || actor.key) {
    context.actor = {
      actor_key: actor.key ?? null,
      display_name: actor.displayName ?? null,
      injected: Boolean(room && !room.isDM && shouldInjectActor(actor, history))
    }
  }

  const speaker = normalizeContextLine(input.speaker)
  const speakerRole = normalizeContextLine(input.speakerRole)
  const speakerTrigger = normalizeContextLine(input.speakerTrigger)
  if (speaker || speakerRole || speakerTrigger) {
    context.speaker = {
      display_name: speaker ?? null,
      role: speakerRole ?? null,
      trigger: speakerTrigger ?? null,
      injected: true
    }
  }

  const think = normalizeContextLine(input.think)
  if (think) {
    context.think = {
      text: think,
      injected: true
    }
  }

  return context
}

export function mergeMessageContextMetadata(metadata: JsonObject | undefined, context: JsonObject): JsonObject {
  return {
    ...metadata,
    [MESSAGE_CONTEXT_METADATA_KEY]: context
  }
}

export function appendMessageContextHistory(history: MessageContextHistoryItem[], metadata: JsonObject): void {
  history.push({ metadata })
}

export function renderMessageWithContext(message: AgentMessage, metadata: JsonObject): AgentMessage {
  if (message.role !== 'user') return message
  const prefix = renderMessageContextPrefix(metadata)
  if (!prefix) return message

  if (typeof message.content === 'string') {
    return {
      ...message,
      content: `${prefix}\n\n${message.content}`
    }
  }

  const content = [...message.content]
  const firstTextIndex = content.findIndex(block => block.type === 'text')
  if (firstTextIndex < 0) {
    return {
      ...message,
      content: [{ type: 'text', text: prefix }, ...content]
    }
  }

  const firstText = content[firstTextIndex] as TextContent
  content[firstTextIndex] = {
    ...firstText,
    text: `${prefix}\n\n${firstText.text}`
  }

  return {
    ...message,
    content
  }
}

export function renderMessageContextPrefix(metadata: JsonObject): string | undefined {
  const context = toJsonObject(metadata[MESSAGE_CONTEXT_METADATA_KEY])
  const lines: string[] = []

  const time = toJsonObject(context.time)
  if (time.injected === true && typeof time.sent_at === 'string') {
    const timezone = typeof time.timezone === 'string' ? time.timezone : undefined
    lines.push(`sent_at: ${formatTimestamp(time.sent_at, timezone)}`)
  }

  const actor = toJsonObject(context.actor)
  const room = toJsonObject(context.room)
  if (room.injected === true && typeof room.label === 'string') lines.push(`room: ${room.label}`)

  const speaker = toJsonObject(context.speaker)
  if (speaker.injected === true) {
    if (typeof speaker.display_name === 'string') lines.push(`speaker: ${speaker.display_name}`)
    if (typeof speaker.role === 'string') lines.push(`speaker_role: ${speaker.role}`)
    if (typeof speaker.trigger === 'string') lines.push(`speaker_trigger: ${speaker.trigger}`)
  } else if (actor.injected === true && typeof actor.display_name === 'string') {
    lines.push(`speaker: ${actor.display_name}`)
  }

  const think = toJsonObject(context.think)
  if (think.injected === true && typeof think.text === 'string') lines.push(`think: ${think.text}`)

  return lines.length > 0 ? `<message_context>\n${lines.join('\n')}\n</message_context>` : undefined
}

function shouldInjectTime(sentAt: Date, history: MessageContextHistoryItem[]): boolean {
  const previous = findLastContext(history, context => {
    const time = toJsonObject(context.time)
    if (typeof time.sent_at !== 'string') return undefined
    const parsed = new Date(time.sent_at)
    return Number.isNaN(parsed.getTime()) ? undefined : parsed
  })
  return Boolean(previous && sentAt.getTime() - previous.getTime() >= TIME_CONTEXT_GAP_MS)
}

function shouldInjectRoom(room: RoomContext, history: MessageContextHistoryItem[]): boolean {
  const previous = findLastContext(history, context => {
    const value = toJsonObject(context.room)
    if (value.injected !== true) return undefined
    const id = typeof value.id === 'string' ? value.id : undefined
    const label = typeof value.label === 'string' ? value.label : undefined
    return id || label ? { id, label } : undefined
  })
  return !previous || previous.id !== room.id || previous.label !== room.label
}

function shouldInjectActor(actor: ActorContext, history: MessageContextHistoryItem[]): boolean {
  const current = actor.key ?? actor.displayName
  if (!current) return false

  const previousContext = lastMessageContext(history)
  if (!previousContext) return true
  const value = toJsonObject(previousContext.actor)
  const previous = (typeof value.actor_key === 'string' && value.actor_key) || stringFromNullable(value.display_name)
  return previous !== current
}

function lastMessageContext(history: MessageContextHistoryItem[]): JsonObject | undefined {
  for (let index = history.length - 1; index >= 0; index -= 1) {
    return toJsonObject(history[index]!.metadata[MESSAGE_CONTEXT_METADATA_KEY])
  }
  return undefined
}

function findLastContext<T>(
  history: MessageContextHistoryItem[],
  pick: (context: JsonObject) => T | undefined
): T | undefined {
  for (let index = history.length - 1; index >= 0; index -= 1) {
    const context = toJsonObject(history[index]!.metadata[MESSAGE_CONTEXT_METADATA_KEY])
    const value = pick(context)
    if (value !== undefined) return value
  }
  return undefined
}

interface ActorContext {
  displayName?: string
  key?: string
}

function actorContext(actor: JsonObject | undefined): ActorContext {
  const source = toJsonObject(actor ?? {})
  const key =
    stringFromPath(source, ['userId']) ??
    stringFromPath(source, ['external_account_id']) ??
    stringFromPath(source, ['id']) ??
    stringFromPath(source, ['open_id'])
  const displayName =
    stringFromPath(source, ['fullName']) ??
    stringFromPath(source, ['userName']) ??
    stringFromPath(source, ['display_name']) ??
    stringFromPath(source, ['name']) ??
    key

  return {
    key: key ? key.slice(0, 160) : undefined,
    displayName: displayName ? displayName.slice(0, 160) : undefined
  }
}

interface RoomContext {
  id?: string
  isDM: boolean
  label: string
  name?: string
}

function roomContext(room: JsonObject | undefined, actorDisplayName: string | undefined): RoomContext | undefined {
  const source = toJsonObject(room ?? {})
  const id = stringFromPath(source, ['id'])
  const name = stringFromPath(source, ['name'])
  const isDM = source.isDM === true || source.is_dm === true
  if (!id && !name && !actorDisplayName) return undefined

  const label = isDM
    ? `direct message with ${actorDisplayName ?? name ?? id ?? 'unknown user'}`
    : name
      ? `group chat "${name}"`
      : `group chat ${id ?? 'unknown'}`

  return {
    id,
    isDM,
    label,
    name
  }
}

function normalizeContextLine(value: string | undefined): string | undefined {
  const text = value?.trim().replace(/\s+/g, ' ').slice(0, MAX_CONTEXT_LINE_TEXT)
  return text || undefined
}

function formatTimestamp(value: string, timezone?: string): string {
  const parsed = new Date(value)
  if (Number.isNaN(parsed.getTime()) || !timezone) return value
  const parts = zonedParts(timezone, parsed)
  return `${pad(parts.year, 4)}-${pad(parts.month)}-${pad(parts.day)} ${pad(parts.hour)}:${pad(parts.minute)}:${pad(parts.second)} (${timezone})`
}

function pad(value: number, length = 2): string {
  return value.toString().padStart(length, '0')
}

function stringFromNullable(value: unknown): string | undefined {
  return typeof value === 'string' && value.length > 0 ? value : undefined
}
