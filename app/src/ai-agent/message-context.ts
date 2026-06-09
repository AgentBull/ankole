import { and, asc, eq, sql } from 'drizzle-orm'
import type { TextContent } from '@earendil-works/pi-ai'
import { DB, type QueryExecutor } from '@/common/database'
import { AiAgentMessages, type JsonObject, type JsonValue } from '@/common/db-schema'
import { isJsonObject, stringFromPath, toJsonObject } from '@/common/json'
import type { AgentMessage } from './core'
import { textFromContent } from './conversation-service'

export const MESSAGE_CONTEXT_METADATA_KEY = 'message_context'

const TIME_CONTEXT_GAP_MS = 60 * 60 * 1000
const MAX_AMBIENT_REFERENCE_SNIPPETS = 12
const MAX_AMBIENT_REFERENCE_TEXT = 800

export interface MessageContextInput {
  actor?: JsonObject
  ambientReferences?: AmbientReferenceSnippet[]
  room?: JsonObject
  sentAt: Date
}

export interface MessageContextHistoryItem {
  metadata: JsonObject
}

export interface AmbientReferenceSnippet {
  actorDisplayName?: string
  sentAt?: string
  text: string
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
  const sentAt = truncateToSecond(input.sentAt)
  const actor = actorContext(input.actor)
  const room = roomContext(input.room, actor.displayName)
  const context: JsonObject = {
    time: {
      sent_at: sentAt.toISOString(),
      injected: shouldInjectTime(sentAt, history),
      gap_ms: TIME_CONTEXT_GAP_MS
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

  const ambientReferences = normalizeAmbientReferences(input.ambientReferences)
  if (ambientReferences.length > 0) {
    context.ambient_references = {
      injected: true,
      snippets: ambientReferences as unknown as JsonValue[]
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
    lines.push(`sent_at: ${formatTimestamp(time.sent_at)}`)
  }

  const room = toJsonObject(context.room)
  if (room.injected === true && typeof room.label === 'string') lines.push(`room: ${room.label}`)

  const actor = toJsonObject(context.actor)
  if (actor.injected === true && typeof actor.display_name === 'string') lines.push(`speaker: ${actor.display_name}`)

  const prefixBlocks: string[] = []
  if (lines.length > 0) prefixBlocks.push(`<message_context>\n${lines.join('\n')}\n</message_context>`)

  const ambientReference = renderAmbientReferenceBlock(context)
  if (ambientReference) prefixBlocks.push(ambientReference)

  return prefixBlocks.length > 0 ? prefixBlocks.join('\n') : undefined
}

export function ambientReferenceSnippetsFromRows(
  rows: Array<{ content: JsonValue[]; createdAt: Date; metadata: JsonObject }>
): AmbientReferenceSnippet[] {
  return rows.map(row => {
    const context = toJsonObject(row.metadata[MESSAGE_CONTEXT_METADATA_KEY])
    return {
      actorDisplayName:
        stringFromPath(context, ['actor', 'display_name']) ??
        stringFromPath(row.metadata, ['actor', 'fullName']) ??
        stringFromPath(row.metadata, ['actor', 'userName']) ??
        stringFromPath(row.metadata, ['actor', 'display_name']),
      sentAt: stringFromPath(context, ['time', 'sent_at']) ?? row.createdAt.toISOString(),
      text: textFromContent(row.content).slice(0, MAX_AMBIENT_REFERENCE_TEXT)
    }
  })
}

function renderAmbientReferenceBlock(context: JsonObject): string | undefined {
  const ambient = toJsonObject(context.ambient_references)
  if (ambient.injected !== true || !Array.isArray(ambient.snippets)) return undefined

  const lines = ambient.snippets.flatMap(snippetValue => {
    if (!isJsonObject(snippetValue)) return []
    const text = typeof snippetValue.text === 'string' ? snippetValue.text.trim() : ''
    if (!text) return []
    const sentAt = typeof snippetValue.sentAt === 'string' ? formatTimestamp(snippetValue.sentAt) : 'unknown time'
    const actor =
      typeof snippetValue.actorDisplayName === 'string' && snippetValue.actorDisplayName.trim()
        ? snippetValue.actorDisplayName.trim()
        : 'unknown speaker'
    return [`- ${sentAt} ${actor}: ${text}`]
  })

  return lines.length > 0 ? `<ambient_reference_context>\n${lines.join('\n')}\n</ambient_reference_context>` : undefined
}

function shouldInjectTime(sentAt: Date, history: MessageContextHistoryItem[]): boolean {
  const previous = findLastContext(history, context => {
    const time = toJsonObject(context.time)
    if (time.injected !== true || typeof time.sent_at !== 'string') return undefined
    const parsed = new Date(time.sent_at)
    return Number.isNaN(parsed.getTime()) ? undefined : parsed
  })
  return !previous || sentAt.getTime() - previous.getTime() >= TIME_CONTEXT_GAP_MS
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

  const previous = findLastContext(history, context => {
    const value = toJsonObject(context.actor)
    if (value.injected !== true) return undefined
    return (typeof value.actor_key === 'string' && value.actor_key) || stringFromNullable(value.display_name)
  })
  return previous !== current
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

function normalizeAmbientReferences(snippets: AmbientReferenceSnippet[] | undefined): AmbientReferenceSnippet[] {
  return (snippets ?? [])
    .flatMap(snippet => {
      const text = snippet.text.trim().slice(0, MAX_AMBIENT_REFERENCE_TEXT)
      if (!text) return []
      return [
        {
          actorDisplayName: snippet.actorDisplayName?.slice(0, 160),
          sentAt: snippet.sentAt,
          text
        }
      ]
    })
    .slice(-MAX_AMBIENT_REFERENCE_SNIPPETS)
}

function truncateToSecond(date: Date): Date {
  return new Date(Math.floor(date.getTime() / 1000) * 1000)
}

function formatTimestamp(value: string): string {
  const parsed = new Date(value)
  if (Number.isNaN(parsed.getTime())) return value
  return parsed.toISOString()
}

function stringFromNullable(value: unknown): string | undefined {
  return typeof value === 'string' && value.length > 0 ? value : undefined
}
