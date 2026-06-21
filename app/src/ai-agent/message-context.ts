import { and, asc, eq, sql } from 'drizzle-orm'
import { ms } from '@pleisto/active-support'
import type { TextContent } from '@/llm'
import { DB, type QueryExecutor } from '@/common/database'
import { AiAgentMessages, type JsonObject } from '@/common/db-schema'
import { stringFromPath, toJsonObject } from '@/common/json'
import { zonedParts } from '@/config/system'
import type { AgentMessage } from './core'

// Ambient scene facts (who is speaking, in which room, at what time, the trigger reasoning) are prepended
// to a user message as a small `<message_context>` block so the model knows the situation without it
// being baked into the message body. The guiding principle is SPARSE injection: each fact is emitted only
// when it CHANGED since the last message — repeating an unchanged room/speaker/timestamp on every turn
// would burn tokens and train the model to ignore the block. The decision (`injected: true/false`) is
// computed once at write time and frozen in the message metadata, so a later re-render reproduces the
// exact same prefix instead of re-deciding against a now-different history.

export const MESSAGE_CONTEXT_METADATA_KEY = 'message_context'

// A timestamp is re-injected only after at least this much wall-clock gap, so the model is reminded of
// "now" when a conversation resumes after a pause, but not on every rapid back-and-forth message.
const TIME_CONTEXT_GAP_MS = ms('1h')
// Hard cap on any single rendered context line, defending the prompt against an oversized display
// name / room title / think string.
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

/**
 * Loads the prior incoming-message metadata that the change-detection below compares against.
 *
 * Restricted to the messages that actually carry a `message_context` decision: real inbound user / ambient
 * messages of a normal-or-introspection kind. Rows with a `transcript_effect` (edits, redactions, and
 * other rewrites of history) are excluded so their synthetic context does not skew "what did the last real
 * message show". Ordered oldest-first so the helpers can scan from the tail for the most recent value.
 */
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

/**
 * Computes the frozen `message_context` metadata for one incoming message: the full set of scene facts,
 * each tagged with whether it should actually be rendered (`injected`).
 *
 * Both the value and the inject/skip decision are stored. Persisting the decision — rather than just the
 * raw facts — is what lets {@link renderMessageContextPrefix} reproduce the same prefix on every later
 * render without re-running change detection against a history that has since moved on.
 *
 * `speaker`/`think` are introspection-trigger fields supplied by the system itself; they are always
 * trusted and always injected. `time`/`room`/`actor` are sparse: each is injected only when it changed
 * versus `history` (and actor only in group rooms, where "who is talking" is ambiguous).
 */
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
      // Who-is-speaking only matters in a group room; in a DM the sender is unambiguous, so it is never
      // injected there. In a group it is injected only when the speaker changed from the prior message.
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

/** Stores the computed context under its reserved key without disturbing the rest of a message's metadata. */
export function mergeMessageContextMetadata(metadata: JsonObject | undefined, context: JsonObject): JsonObject {
  return {
    ...metadata,
    [MESSAGE_CONTEXT_METADATA_KEY]: context
  }
}

/**
 * Appends a just-built context to the in-memory history so the NEXT message in the same batch compares
 * against it. Used when several incoming messages are processed in one pass, before any of them is
 * persisted and reloadable via {@link loadMessageContextHistory}.
 */
export function appendMessageContextHistory(history: MessageContextHistoryItem[], metadata: JsonObject): void {
  history.push({ metadata })
}

/**
 * Prepends the rendered `<message_context>` block to a user message for the model-bound view.
 *
 * Only user messages get a prefix (the block describes an inbound message), and only when something is
 * actually injectable. The prefix is woven into the FIRST text block — not pushed as a separate leading
 * block — so providers that expect a user turn to start with text are not surprised by, e.g., a leading
 * image. Returns the message untouched when it is not a user turn or there is nothing to inject. Operates
 * on a copy; the stored message is never mutated.
 */
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
  // No text block to merge into (e.g. an image-only message): insert the prefix as a new leading text
  // block instead.
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

/**
 * Renders the frozen context metadata into the `<message_context>` text block, emitting only the lines
 * whose stored `injected` flag is set. This is a pure projection of the decisions made at write time — it
 * does no change detection of its own — so it stays deterministic across re-renders. Returns `undefined`
 * when nothing is injectable, which signals callers to add no prefix at all.
 */
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

  // The explicit introspection `speaker` (system-supplied, with role/trigger) wins over the inferred group
  // `actor`: when present it fully describes who is talking and why, so the plain actor line is redundant
  // and is only used as the fallback when there is no speaker block.
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

// Injects a timestamp only when the gap since the last message that carried one is at least
// TIME_CONTEXT_GAP_MS. The first-ever message has no prior time, so it is intentionally NOT injected —
// there is no elapsed gap to convey yet.
function shouldInjectTime(sentAt: Date, history: MessageContextHistoryItem[]): boolean {
  const previous = findLastContext(history, context => {
    const time = toJsonObject(context.time)
    if (typeof time.sent_at !== 'string') return undefined
    const parsed = new Date(time.sent_at)
    return Number.isNaN(parsed.getTime()) ? undefined : parsed
  })
  return Boolean(previous && sentAt.getTime() - previous.getTime() >= TIME_CONTEXT_GAP_MS)
}

// Injects the room only when it differs from the last room actually shown. Compared against the most
// recent INJECTED room (not merely the last message's room) so the model's view of "current room" is the
// reference; a never-before-shown room (no previous) is always injected.
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

// Injects the speaker only when it changed from the IMMEDIATELY preceding message (not the last injected
// one). Identity is keyed on the stable actor key when available, falling back to display name. A first
// message (no prior context) always injects.
function shouldInjectActor(actor: ActorContext, history: MessageContextHistoryItem[]): boolean {
  const current = actor.key ?? actor.displayName
  if (!current) return false

  const previousContext = lastMessageContext(history)
  if (!previousContext) return true
  const value = toJsonObject(previousContext.actor)
  const previous = (typeof value.actor_key === 'string' && value.actor_key) || stringFromNullable(value.display_name)
  return previous !== current
}

// The single most recent message's context. Note this returns on the FIRST iteration: it deliberately
// reads only the last entry (used by actor detection, which compares against the immediately prior
// message rather than scanning back for the last injected value).
function lastMessageContext(history: MessageContextHistoryItem[]): JsonObject | undefined {
  for (let index = history.length - 1; index >= 0; index -= 1) {
    return toJsonObject(history[index]!.metadata[MESSAGE_CONTEXT_METADATA_KEY])
  }
  return undefined
}

// Scans history newest-first and returns the first value `pick` extracts, skipping messages for which it
// returns undefined. This is how time/room detection finds the last message that actually carried (or
// showed) the fact, rather than just the previous message.
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

/**
 * Normalizes a raw actor object from any channel adapter into a stable `{key, displayName}`.
 *
 * Adapters disagree on field names, so id and name are each resolved by trying a priority list of known
 * aliases (camelCase and snake_case). The display name falls back to the key when no human-readable name
 * exists, and both are length-capped so a hostile or huge value cannot bloat the context line.
 */
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

/**
 * Normalizes a raw room object into a human-readable `RoomContext`, or `undefined` when there is nothing
 * identifiable to describe. Builds a natural-language label the model reads directly ("direct message
 * with Alice", `group chat "Ops"`), preferring a DM-with-person phrasing, then a named group, then a
 * bare-id group as the last fallback.
 */
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

// Collapses internal whitespace to single spaces and caps the length, so multi-line or padded input
// renders as one tidy context line. Returns undefined for empty/whitespace-only input so callers can omit
// the field entirely.
function normalizeContextLine(value: string | undefined): string | undefined {
  const text = value?.trim().replace(/\s+/g, ' ').slice(0, MAX_CONTEXT_LINE_TEXT)
  return text || undefined
}

// Renders the stored UTC instant in the conversation's own timezone so the model reads a local wall-clock
// time. Falls back to the raw ISO string when the timestamp is unparseable or no timezone is known,
// rather than guessing.
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
