import { genUUIDv7 } from '@agentbull/bullx-native-addons'
import type { Message, ReactionEvent } from 'chat'
import { and, eq, sql } from 'drizzle-orm'
import { DB, jsonbParam, type QueryExecutor } from '@/common/database'
import { ChatChannels, ChatMessages, type JsonObject, type JsonValue } from '@/common/db-schema'

export type ChatGatewayChannel = typeof ChatChannels.$inferSelect
export type ChatGatewayMessage = typeof ChatMessages.$inferSelect

/**
 * Structural subset of Chat SDK `Channel` required by the latest-state mirror.
 *
 * Chat SDK's public event types currently do not use one consistent generic
 * shape for `Thread`, but every real Thread still exposes the same channel
 * facts. Keeping the projection boundary structural avoids leaking that SDK
 * generic mismatch into adapter code while still requiring Chat SDK channel
 * identity.
 */
export interface ChatGatewayProjectionThreadChannel {
  id: string
  isDM: boolean
  channelVisibility: string
  name?: string | null
  toJSON(): unknown
}

/**
 * Structural subset of Chat SDK `Thread` used by the projection sink.
 *
 * Callers should pass the actual Chat SDK Thread they received from a handler
 * or event. The projection only reads identity/serialization fields and never
 * posts, subscribes, or mutates thread state.
 */
export interface ChatGatewayProjectionThread {
  id: string
  channelId: string
  channel: ChatGatewayProjectionThreadChannel
}

export interface ChatGatewayProjectMessageInput<TRawMessage = unknown> {
  /**
   * Chat SDK Thread that delivered the message.
   *
   * The projection channel is the Thread's owning Channel. Adapters should not
   * pass local factory ids, provider ids, or hand-built channel identities; those
   * concerns belong inside the Chat SDK adapter that created the Thread.
   */
  thread: ChatGatewayProjectionThread
  /**
   * Normalized Chat SDK Message received from a Chat SDK handler/event.
   *
   * `message.toJSON()` is used where the SDK already knows how to remove
   * non-serializable attachment data. Projection code stores this SDK fact; it
   * does not reinterpret provider-specific payloads.
   */
  message: Message<TRawMessage>
}

export interface ChatGatewayProjectDeleteInput<TRawMessage = unknown> {
  /**
   * Chat SDK Thread where the delete event was observed.
   */
  thread: ChatGatewayProjectionThread
  /**
   * Chat SDK Message id to remove from the latest-state projection.
   */
  messageId: string
}

/**
 * Latest-state projection API exposed to Chat Gateway adapter factories.
 *
 * Adapters call this after they normalize external-platform events into Chat
 * SDK facts.
 * The sink deliberately stores only Chat SDK-native identities: channel id,
 * message id, and thread id. Local factory ids and agent/webhook context are
 * runtime routing details and never become projection identity.
 */
export interface ChatGatewayProjectionSink {
  /**
   * Projects a Chat SDK Message into the latest-state channel/message tables.
   */
  projectMessage<TRawMessage = unknown>(input: ChatGatewayProjectMessageInput<TRawMessage>): Promise<ChatGatewayMessage>
  /**
   * Projects a Chat SDK delete observation as a hard delete.
   */
  projectDelete<TRawMessage = unknown>(input: ChatGatewayProjectDeleteInput<TRawMessage>): Promise<boolean>
  /**
   * Projects a Chat SDK ReactionEvent. When the event carries a message
   * snapshot, the message is projected before the reaction.
   */
  projectReaction<TRawMessage = unknown>(event: ReactionEvent<TRawMessage>): Promise<boolean>
}

/**
 * PostgreSQL-backed latest-state projection for external chat channels.
 *
 * This is intentionally separate from Chat SDK `StateAdapter`: state tables are
 * runtime coordination primitives, while `chat_channels`/`chat_messages` are the
 * durable mirror that long-term memory can query.
 */
export class DrizzleChatGatewayProjectionSink implements ChatGatewayProjectionSink {
  /**
   * Projects a normalized Chat SDK Message into PostgreSQL.
   *
   * The owning channel comes from `thread.channel`. This keeps the projection
   * centered on Chat SDK's Channel/Thread/Message model and prevents adapter
   * factories from passing hand-built channel identities into the persistence
   * layer.
   */
  async projectMessage<TRawMessage = unknown>(
    input: ChatGatewayProjectMessageInput<TRawMessage>
  ): Promise<ChatGatewayMessage> {
    return upsertProjectedMessage(normalizeMessageFromChatSdk(input.thread, input.message))
  }

  async projectDelete<TRawMessage = unknown>(input: ChatGatewayProjectDeleteInput<TRawMessage>): Promise<boolean> {
    return deleteProjectedMessage(input.thread, input.messageId)
  }

  async projectReaction<TRawMessage = unknown>(event: ReactionEvent<TRawMessage>): Promise<boolean> {
    if (event.message) {
      // A reaction event can be the first time BullX sees enough message data,
      // especially after a restart or if the external platform includes the
      // reacted message snapshot. Project it before applying the reaction
      // instead of creating a placeholder row with missing message facts.
      await this.projectMessage({
        thread: event.thread,
        message: event.message
      })
    }

    return applyProjectedReaction(event)
  }
}

export const chatGatewayProjectionSink: ChatGatewayProjectionSink = new DrizzleChatGatewayProjectionSink()

interface NormalizedMessageInput {
  channel: NormalizedChannelInput
  threadId: string
  messageId: string
  authorId: string | null
  userKey: string | null
  author: JsonObject
  isMention: boolean
  text: string | null
  formatted: JsonObject
  attachments: JsonValue[]
  links: JsonValue[]
  metadata: JsonObject
  reactions: JsonObject
  raw: JsonValue | null
  sentAt: Date | null
  editedAt: Date | null
}

interface NormalizedChannelInput {
  id: string
  isDM: boolean
  channelVisibility: string
  name?: string | null
  metadata?: JsonObject
  raw?: JsonValue | null
}

interface NormalizedReactionEvent {
  added: boolean
  emoji: string
  rawEmoji?: string
  actorId: string
  actor: JsonObject
  raw: JsonValue | null
}

async function upsertProjectedMessage(input: NormalizedMessageInput): Promise<ChatGatewayMessage> {
  return DB.transaction(async tx => {
    const channel = await upsertChannelWithDb(tx, input.channel)
    const [message] = await tx
      .insert(ChatMessages)
      .values({
        id: genUUIDv7(),
        channelId: channel.id,
        threadId: input.threadId,
        messageId: input.messageId,
        authorId: input.authorId,
        userKey: input.userKey,
        author: jsonbParam(input.author),
        isMention: input.isMention,
        text: input.text,
        formatted: jsonbParam(input.formatted),
        attachments: jsonbParam(input.attachments),
        links: jsonbParam(input.links),
        metadata: jsonbParam(input.metadata),
        reactions: jsonbParam(input.reactions),
        raw: jsonbParam(input.raw),
        sentAt: input.sentAt,
        editedAt: input.editedAt
      })
      .onConflictDoUpdate({
        target: [ChatMessages.channelId, ChatMessages.messageId],
        set: {
          threadId: input.threadId,
          authorId: input.authorId,
          userKey: input.userKey,
          author: jsonbParam(input.author),
          isMention: input.isMention,
          text: input.text,
          formatted: jsonbParam(input.formatted),
          attachments: jsonbParam(input.attachments),
          links: jsonbParam(input.links),
          metadata: jsonbParam(input.metadata),
          reactions: jsonbParam(input.reactions),
          raw: jsonbParam(input.raw),
          sentAt: input.sentAt,
          editedAt: input.editedAt,
          updatedAt: sql`now()`
        }
      })
      .returning()

    return message
  })
}

async function deleteProjectedMessage<TRawMessage>(
  thread: ChatGatewayProjectionThread,
  messageId: string
): Promise<boolean> {
  const channel = await findChannelById(channelIdFromThread(thread))
  if (!channel) return false

  const deleted = await DB.delete(ChatMessages)
    .where(
      and(eq(ChatMessages.channelId, channel.id), eq(ChatMessages.messageId, ensureNonEmpty(messageId, 'messageId')))
    )
    .returning({ id: ChatMessages.id })

  return deleted.length > 0
}

async function applyProjectedReaction<TRawMessage>(event: ReactionEvent<TRawMessage>): Promise<boolean> {
  const channel = await findChannelById(channelIdFromThread(event.thread))
  if (!channel) return false

  const rows = await DB.select({ id: ChatMessages.id, reactions: ChatMessages.reactions })
    .from(ChatMessages)
    .where(
      and(eq(ChatMessages.channelId, channel.id), eq(ChatMessages.messageId, ensureNonEmpty(event.messageId, 'messageId')))
    )
    .limit(1)
  const row = rows[0]
  if (!row) return false

  const reactions = applyReactionEvent(row.reactions, normalizeReactionEvent(event))
  await DB.update(ChatMessages)
    .set({
      reactions: jsonbParam(reactions),
      updatedAt: sql`now()`
    })
    .where(eq(ChatMessages.id, row.id))

  return true
}

async function upsertChannelWithDb(db: QueryExecutor, input: NormalizedChannelInput): Promise<ChatGatewayChannel> {
  const [channel] = await db
    .insert(ChatChannels)
    .values({
      id: input.id,
      isDM: input.isDM,
      channelVisibility: input.channelVisibility,
      name: input.name ?? null,
      metadata: jsonbParam(input.metadata ?? {}),
      raw: jsonbParam(input.raw ?? null)
    })
    .onConflictDoUpdate({
      target: ChatChannels.id,
      set: {
        isDM: input.isDM,
        channelVisibility: input.channelVisibility,
        name: input.name === undefined ? sql`${ChatChannels.name}` : input.name,
        metadata: input.metadata === undefined ? sql`${ChatChannels.metadata}` : jsonbParam(input.metadata),
        raw: input.raw === undefined ? sql`${ChatChannels.raw}` : jsonbParam(input.raw),
        updatedAt: sql`now()`
      }
    })
    .returning()

  return channel
}

function normalizeChannelFromThread(thread: ChatGatewayProjectionThread): NormalizedChannelInput {
  const channel = thread.channel

  return {
    id: channelIdFromThread(thread),
    isDM: channel.isDM,
    channelVisibility: channel.channelVisibility,
    name: channel.name ?? undefined,
    metadata: {},
    raw: toJsonValue(channel.toJSON())
  }
}

function normalizeMessageFromChatSdk<TRawMessage>(
  thread: ChatGatewayProjectionThread,
  message: Message<TRawMessage>
): NormalizedMessageInput {
  const serialized = toJsonObject(message.toJSON())
  // Some platforms emit edit events with an edited flag but no timestamp. In
  // that case, `edited_at` records when BullX observed the edited latest state.
  const editedAt = message.metadata.edited ? (message.metadata.editedAt ?? new Date()) : null

  return {
    channel: normalizeChannelFromThread(thread),
    threadId: ensureNonEmpty(message.threadId, 'threadId'),
    messageId: ensureNonEmpty(message.id, 'messageId'),
    authorId: message.author.userId,
    userKey: message.userKey ?? null,
    author: toJsonObject(message.author),
    isMention: message.isMention ?? false,
    text: message.text || null,
    formatted: toJsonObject(message.formatted),
    attachments: toJsonArray(serialized.attachments),
    links: toJsonArray(serialized.links),
    metadata: toJsonObject(message.metadata),
    reactions: {},
    raw: toJsonValue(message.raw),
    sentAt: message.metadata.dateSent,
    editedAt
  }
}

function channelIdFromThread(thread: ChatGatewayProjectionThread): string {
  return ensureNonEmpty(thread.channel.id || thread.channelId, 'channelId')
}

function normalizeReactionEvent(input: ReactionEvent): NormalizedReactionEvent {
  // Chat SDK ReactionEvent carries both normalized emoji and raw platform emoji.
  // Store the normalized value as the map key, but keep the raw value for
  // UI/debugging because platforms may use aliases or custom names.
  return {
    added: input.added,
    emoji: String(input.emoji),
    rawEmoji: input.rawEmoji,
    actorId: input.user.userId,
    actor: toJsonObject(input.user),
    raw: toJsonValue(input.raw)
  }
}

function applyReactionEvent(reactions: JsonObject, reaction: NormalizedReactionEvent): JsonObject {
  const reactionKey = ensureNonEmpty(reaction.emoji || reaction.rawEmoji || '', 'reaction.emoji')
  const next: JsonObject = { ...reactions }
  const current = toJsonObject(next[reactionKey])
  const actors = toJsonObject(current.actors)

  // Chat SDK reaction events always include the reacting user, so actor maps are
  // the canonical latest-state representation and repeated delivery stays
  // idempotent.
  if (reaction.added) actors[reaction.actorId] = reaction.actor
  else delete actors[reaction.actorId]

  const actorCount = Object.keys(actors).length
  if (actorCount <= 0) {
    delete next[reactionKey]
    return next
  }

  const updated: JsonObject = {
    emoji: reactionKey,
    rawEmoji: reaction.rawEmoji ?? reactionKey,
    count: actorCount,
    actors
  }

  updated.raw = reaction.raw

  next[reactionKey] = updated
  return next
}

async function findChannelById(id: string): Promise<ChatGatewayChannel | undefined> {
  const rows = await DB.select().from(ChatChannels).where(eq(ChatChannels.id, id)).limit(1)
  return rows[0]
}

function ensureNonEmpty(value: string, label: string): string {
  if (value.length === 0) throw new ChatGatewayProjectionError(`${label} must not be empty`)

  return value
}

function toJsonValue(value: unknown): JsonValue | null {
  if (value === undefined) return null

  try {
    // Projection tables should contain durable JSON facts, not executable
    // closures, binary payloads, or values PostgreSQL jsonb cannot represent.
    // Chat SDK Message.toJSON() handles its own common omissions; this helper is
    // the final guard for adapter-provided raw payloads and extension fields.
    const serialized = JSON.stringify(value, (_key, nestedValue) => {
      if (
        typeof nestedValue === 'function' ||
        typeof nestedValue === 'undefined' ||
        typeof nestedValue === 'bigint' ||
        typeof nestedValue === 'symbol'
      ) {
        return undefined
      }

      if (nestedValue instanceof Date) return nestedValue.toISOString()

      if (isBinaryLike(nestedValue)) return undefined

      return nestedValue
    })

    return serialized === undefined ? null : (JSON.parse(serialized) as JsonValue)
  } catch {
    return null
  }
}

function toJsonObject(value: unknown): JsonObject {
  const json = toJsonValue(value)
  if (typeof json === 'object' && json !== null && !Array.isArray(json)) return json

  return {}
}

function toJsonArray(value: unknown): JsonValue[] {
  const json = toJsonValue(value)
  return Array.isArray(json) ? json : []
}

function isBinaryLike(value: unknown): boolean {
  return value instanceof ArrayBuffer || value instanceof Blob || ArrayBuffer.isView(value)
}

export class ChatGatewayProjectionError extends Error {
  constructor(message: string) {
    super(message)
    this.name = 'ChatGatewayProjectionError'
  }
}
