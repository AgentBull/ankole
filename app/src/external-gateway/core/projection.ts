import { and, eq, sql } from 'drizzle-orm'
import { genUUIDv7 } from '@agentbull/bullx-native-addons'
import { DB, jsonbParam, type QueryExecutor } from '@/common/database'
import { toJsonArray, toJsonObject, toJsonValue } from '@/common/json'
import { ExternalRooms, ExternalMessages, type JsonObject, type JsonValue } from '@/common/db-schema'
import { projectChatRecallDocument } from '@/chat-recall/projection'
import type { ExternalGatewayMessageInput, ExternalGatewayReactionEvent, ExternalGatewayRoomInput } from './events'

type ExternalGatewayChannel = typeof ExternalRooms.$inferSelect
export type ExternalGatewayMessage = typeof ExternalMessages.$inferSelect

// `room.id` is forced to be present (the rest of the room is optional): a
// projection row is keyed by room, so a message cannot be mirrored without
// knowing which room it belongs to, even when every other room field is unknown.
export interface ExternalGatewayProjectMessageInput<TRawMessage = unknown> {
  message: ExternalGatewayMessageInput<TRawMessage>
  room: Required<Pick<ExternalGatewayRoomInput, 'id'>> & ExternalGatewayRoomInput
}

export interface ExternalGatewayProjectDeleteInput {
  room: Required<Pick<ExternalGatewayRoomInput, 'id'>> & ExternalGatewayRoomInput
  messageId: string
}

/**
 * Latest-state projection API exposed to External Gateway adapter factories.
 *
 * Adapters call this after they normalize provider events into External Gateway
 * facts. The sink deliberately stores only external identities: room id,
 * message id, and thread id. Agent, binding, and webhook routing context are
 * runtime delivery details and never become projection identity.
 */
export interface ExternalGatewayProjectionSink {
  /**
   * Projects a normalized provider message into the latest-state room/message tables.
   */
  projectMessage<TRawMessage = unknown>(
    input: ExternalGatewayProjectMessageInput<TRawMessage>
  ): Promise<ExternalGatewayMessage>
  /**
   * Projects a provider delete/recall observation as a hard delete.
   */
  projectDelete(input: ExternalGatewayProjectDeleteInput): Promise<boolean>
  /**
   * Projects a provider reaction event. When the event carries a message
   * snapshot, the message is projected before the reaction.
   */
  projectReaction<TRawMessage = unknown>(event: ExternalGatewayReactionEvent<TRawMessage>): Promise<boolean>
}

/**
 * PostgreSQL-backed latest-state projection for external chat channels.
 *
 * This is intentionally separate from External Gateway runtime state:
 * input windows, tombstones, and outbox rows coordinate work, while
 * `external_rooms`/`external_messages` are the durable external mirror that
 * long-term memory can query.
 */
export class DrizzleExternalGatewayProjectionSink implements ExternalGatewayProjectionSink {
  /**
   * Projects a normalized provider message into PostgreSQL.
   */
  async projectMessage<TRawMessage = unknown>(
    input: ExternalGatewayProjectMessageInput<TRawMessage>
  ): Promise<ExternalGatewayMessage> {
    return upsertProjectedMessage(normalizeMessageFromInput(input))
  }

  async projectDelete(input: ExternalGatewayProjectDeleteInput): Promise<boolean> {
    return deleteProjectedMessage(normalizeRoomInput(input.room), input.messageId)
  }

  async projectReaction<TRawMessage = unknown>(event: ExternalGatewayReactionEvent<TRawMessage>): Promise<boolean> {
    if (event.message) {
      // A reaction event can be the first time BullX sees enough message data,
      // especially after a restart or if the external platform includes the
      // reacted message snapshot. Project it before applying the reaction
      // instead of creating a placeholder row with missing message facts.
      await this.projectMessage({
        room: normalizeRoomFromEvent(event),
        message: event.message
      })
    }

    return applyProjectedReaction(event)
  }
}

export const externalGatewayProjectionSink: ExternalGatewayProjectionSink = new DrizzleExternalGatewayProjectionSink()

interface NormalizedMessageInput {
  room: NormalizedRoomInput
  messageId: string
  authorId: string | null
  userKey: string | null
  author: JsonObject
  mentions: JsonValue[]
  text: string | null
  formatted: JsonObject
  attachments: JsonValue[]
  links: JsonValue[]
  metadata: JsonObject
  reactions: JsonObject
  raw: JsonValue | null
  sentAt: Date | null
}

interface NormalizedRoomInput {
  id: string
  isDM: boolean
  roomVisibility: string
  name?: string | null
  metadata?: JsonObject
  raw?: JsonValue | null
}

interface NormalizedReactionEvent {
  added: boolean
  /**
   * Stable platform reaction identity used as the JSON object key.
   *
   * Adapters may expose `emoji` as a normalized convenience value, but the
   * external mirror has to preserve the platform-visible reaction bucket. Lark
   * and Slack can have aliases that normalize to the same convenience emoji, so
   * `rawEmoji` wins when it is present.
   */
  key: string
  emoji: string
  rawEmoji?: string
  actorId: string
  actor: JsonObject
  raw: JsonValue | null
}

/**
 * Inserts or updates one mirrored message inside a single transaction.
 *
 * The existing row is locked `for update` because the same provider message id
 * can be projected concurrently — a fresh receive and a reaction event that
 * carries the same message snapshot can race. The lock serializes them so the
 * reaction map and message facts are not clobbered by an interleaving write.
 */
async function upsertProjectedMessage(input: NormalizedMessageInput): Promise<ExternalGatewayMessage> {
  return DB.transaction(async tx => {
    const room = await upsertRoomWithDb(tx, input.room)

    const existingRows = await tx
      .select()
      .from(ExternalMessages)
      .where(and(eq(ExternalMessages.roomId, room.id), eq(ExternalMessages.messageId, input.messageId)))
      .for('update')
      .limit(1)
    const existing = existingRows[0]

    // Drop a projection that is older than what is already stored. Providers can
    // redeliver or deliver out of order, and the latest-state mirror must not
    // regress to a stale snapshot.
    if (existing && isStaleProjection(existing, input)) {
      return existing
    }

    if (existing) {
      const [message] = await tx
        .update(ExternalMessages)
        .set({
          authorId: input.authorId,
          userKey: input.userKey,
          author: jsonbParam(input.author),
          mentions: jsonbParam(input.mentions),
          text: input.text,
          formatted: jsonbParam(input.formatted),
          attachments: jsonbParam(input.attachments),
          links: jsonbParam(input.links),
          metadata: jsonbParam(input.metadata),
          // Message projections and reaction events can arrive through
          // independent platform lifecycles. Refresh message facts without
          // erasing reactions already projected for the same id.
          reactions: jsonbParam(existing.reactions),
          raw: jsonbParam(input.raw),
          // A provider message id denotes one visible message. Preserve the
          // original send time once BullX has observed it. If the first
          // observation lacked a send time, a later richer projection may fill it.
          sentAt: existing.sentAt ?? input.sentAt,
          updatedAt: sql`now()`
        })
        .where(and(eq(ExternalMessages.roomId, room.id), eq(ExternalMessages.messageId, input.messageId)))
        .returning()

      if (!message) throw new ExternalGatewayProjectionError(`Failed to update projected message ${input.messageId}`)

      return projectChatRecallDocument(tx, message)
    }

    const [message] = await tx
      .insert(ExternalMessages)
      .values({
        documentId: genUUIDv7(),
        roomId: room.id,
        messageId: input.messageId,
        authorId: input.authorId,
        userKey: input.userKey,
        author: jsonbParam(input.author),
        mentions: jsonbParam(input.mentions),
        text: input.text,
        formatted: jsonbParam(input.formatted),
        attachments: jsonbParam(input.attachments),
        links: jsonbParam(input.links),
        metadata: jsonbParam(input.metadata),
        reactions: jsonbParam(input.reactions),
        raw: jsonbParam(input.raw),
        sentAt: input.sentAt
      })
      .returning()

    if (!message) throw new ExternalGatewayProjectionError(`Failed to insert projected message ${input.messageId}`)

    return projectChatRecallDocument(tx, message)
  })
}

/**
 * Treats `sentAt` as the revision clock: a projection is stale when its send
 * time predates the stored one. Equal times are not stale, so a redelivery of
 * the same message still refreshes the row's other facts.
 */
function isStaleProjection(existing: ExternalGatewayMessage, input: NormalizedMessageInput): boolean {
  const incoming = projectionRevisionMs(input.sentAt)
  const current = projectionRevisionMs(existing.sentAt)

  return incoming < current
}

// A missing send time sorts as epoch 0, i.e. the oldest possible. A projection
// with no send time therefore never wins against one that has a real time.
function projectionRevisionMs(sentAt: Date | null): number {
  return (sentAt ?? new Date(0)).getTime()
}

/**
 * Hard-deletes the mirrored message. Returns false when the room was never seen
 * or no matching row exists, so a delete for an unknown message is a quiet
 * no-op rather than an error.
 */
async function deleteProjectedMessage(roomInput: NormalizedRoomInput, messageId: string): Promise<boolean> {
  const room = await findRoomById(roomInput.id)
  if (!room) return false

  const deleted = await DB.delete(ExternalMessages)
    .where(
      and(eq(ExternalMessages.roomId, room.id), eq(ExternalMessages.messageId, ensureNonEmpty(messageId, 'messageId')))
    )
    .returning({ messageId: ExternalMessages.messageId })

  return deleted.length > 0
}

/**
 * Applies one reaction add/remove to the stored reaction map.
 *
 * The row is locked `for update` so concurrent reaction events on the same
 * message serialize their read-modify-write of the JSON map instead of one
 * overwriting the other. A reaction on a message that was never projected is a
 * no-op (returns false): the caller is expected to project the message first
 * when it has the snapshot.
 */
async function applyProjectedReaction<TRawMessage>(event: ExternalGatewayReactionEvent<TRawMessage>): Promise<boolean> {
  const room = await findRoomById(roomIdFromReaction(event))
  if (!room) return false

  return DB.transaction(async tx => {
    const rows = await tx
      .select({ reactions: ExternalMessages.reactions })
      .from(ExternalMessages)
      .where(
        and(
          eq(ExternalMessages.roomId, room.id),
          eq(ExternalMessages.messageId, ensureNonEmpty(event.messageId, 'messageId'))
        )
      )
      .for('update')
      .limit(1)
    const row = rows[0]
    if (!row) return false

    const reactions = applyReactionEvent(row.reactions, normalizeReactionEvent(event))
    await tx
      .update(ExternalMessages)
      .set({
        reactions: jsonbParam(reactions),
        updatedAt: sql`now()`
      })
      .where(
        and(
          eq(ExternalMessages.roomId, room.id),
          eq(ExternalMessages.messageId, ensureNonEmpty(event.messageId, 'messageId'))
        )
      )

    return true
  })
}

/**
 * Upserts the room row that owns projected messages.
 *
 * `name`/`metadata`/`raw` distinguish "not provided" from "explicitly cleared":
 * when the field is `undefined` the update keeps the stored value (the
 * `sql`${column}`` self-reference), but an explicit `null` overwrites it. This
 * matters because many events (a reaction, a thread-only fact) carry a room id
 * with no name; those must not blank out a name an earlier richer event set.
 */
async function upsertRoomWithDb(db: QueryExecutor, input: NormalizedRoomInput): Promise<ExternalGatewayChannel> {
  const [room] = await db
    .insert(ExternalRooms)
    .values({
      id: input.id,
      isDM: input.isDM,
      roomVisibility: input.roomVisibility,
      name: input.name ?? null,
      metadata: jsonbParam(input.metadata ?? {}),
      raw: jsonbParam(input.raw ?? null)
    })
    .onConflictDoUpdate({
      target: ExternalRooms.id,
      set: {
        isDM: input.isDM,
        roomVisibility: input.roomVisibility,
        name: input.name === undefined ? sql`${ExternalRooms.name}` : input.name,
        metadata: input.metadata === undefined ? sql`${ExternalRooms.metadata}` : jsonbParam(input.metadata),
        raw: input.raw === undefined ? sql`${ExternalRooms.raw}` : jsonbParam(input.raw),
        updatedAt: sql`now()`
      }
    })
    .returning()

  return room
}

function normalizeRoomInput(
  room: Required<Pick<ExternalGatewayRoomInput, 'id'>> & ExternalGatewayRoomInput
): NormalizedRoomInput {
  return {
    id: ensureNonEmpty(room.id, 'room.id'),
    isDM: room.isDM ?? false,
    roomVisibility: room.roomVisibility ?? 'unknown',
    name: room.name ?? undefined,
    metadata: toJsonObject(room.metadata ?? {}),
    raw: toJsonValue(room.raw)
  }
}

/**
 * Resolves the room for a reaction event, preferring the event's own room.
 *
 * When the event omits a room, the id is recovered from the thread id by taking
 * its first two colon segments — the gateway thread-id convention prefixes the
 * room id, so a reaction with only a thread id can still be attributed to a
 * room. The recovered room carries no name/visibility, which `upsertRoomWithDb`
 * preserves against any richer row already stored.
 */
function normalizeRoomFromEvent(
  event: ExternalGatewayReactionEvent
): Required<Pick<ExternalGatewayRoomInput, 'id'>> & ExternalGatewayRoomInput {
  if (event.room?.id) {
    return normalizeRoomInput(event.room as Required<Pick<ExternalGatewayRoomInput, 'id'>> & ExternalGatewayRoomInput)
  }

  return {
    id: ensureNonEmpty(event.threadId.split(':').slice(0, 2).join(':'), 'room.id'),
    isDM: false,
    roomVisibility: 'unknown'
  }
}

function normalizeMessageFromInput<TRawMessage>(
  input: ExternalGatewayProjectMessageInput<TRawMessage>
): NormalizedMessageInput {
  const message = input.message
  const metadata = toJsonObject(message.metadata ?? {})

  return {
    room: normalizeRoomInput(input.room),
    messageId: ensureNonEmpty(message.id, 'messageId'),
    authorId: message.author.userId,
    userKey: message.userKey ?? null,
    author: toJsonObject(message.author),
    mentions: toJsonArray(message.mentions ?? mentionsFromNormalizedMessage(message)),
    text: message.text ?? null,
    formatted: toJsonObject(message.formatted),
    attachments: toJsonArray(message.attachments ?? []),
    links: toJsonArray(message.links ?? []),
    metadata,
    reactions: {},
    raw: toJsonValue(message.raw),
    sentAt: message.metadata?.dateSent ?? null
  }
}

// Same room-id recovery as normalizeRoomFromEvent, but used only to look up the
// existing row (no upsert), so it returns the bare id.
function roomIdFromReaction(event: ExternalGatewayReactionEvent): string {
  if (event.room?.id) return event.room.id
  return event.threadId.split(':').slice(0, 2).join(':')
}

function normalizeReactionEvent(input: ExternalGatewayReactionEvent): NormalizedReactionEvent {
  // Reaction events carry both normalized emoji and raw platform emoji.
  // Store the platform emoji as the map key when available because that is the
  // provider-visible reaction bucket; keep the normalized value for portable UI
  // labels.
  return {
    added: input.added,
    key: ensureNonEmpty(input.rawEmoji || normalizedEmojiName(input.emoji), 'reaction.key'),
    emoji: normalizedEmojiName(input.emoji),
    rawEmoji: input.rawEmoji,
    actorId: input.user.userId,
    actor: toJsonObject(input.user),
    raw: toJsonValue(input.raw)
  }
}

/**
 * Folds one reaction event into the stored `{ reactionKey: { actors, count } }`
 * map and returns the next map.
 *
 * Reactions are stored as a set of actors per emoji, not a running counter, so
 * `count` is always derived from the actor map. This makes redelivery
 * idempotent (the same actor added twice is still one entry) and lets a remove
 * be applied even if its matching add was missed. When the last actor leaves,
 * the whole emoji bucket is dropped so empty reactions do not linger.
 */
function applyReactionEvent(reactions: JsonObject, reaction: NormalizedReactionEvent): JsonObject {
  const reactionKey = reaction.key
  const next: JsonObject = { ...reactions }
  const current = toJsonObject(next[reactionKey])
  const actors = toJsonObject(current.actors)

  // Reaction events always include the reacting user, so actor maps are
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
    emoji: reaction.emoji,
    rawEmoji: reaction.rawEmoji ?? reactionKey,
    count: actorCount,
    actors
  }

  updated.raw = reaction.raw

  next[reactionKey] = updated
  return next
}

// Different adapters model an emoji as either a bare string or an object with a
// `name`; collapse both to the name string so the stored map has one shape.
function normalizedEmojiName(emoji: unknown): string {
  if (typeof emoji === 'string') return emoji
  if (typeof emoji === 'object' && emoji !== null && 'name' in emoji && typeof emoji.name === 'string') {
    return emoji.name
  }
  return String(emoji)
}

// Fallback when an adapter reports "the bot was mentioned" as a boolean flag but
// gives no structured mention list. Synthesize a single bot mention so the
// mirror records that the bot was addressed, tagged with its source for tracing.
function mentionsFromNormalizedMessage(message: Pick<ExternalGatewayMessageInput, 'isMention'>): JsonValue[] {
  if (!message.isMention) return []

  return [
    {
      kind: 'bot',
      source: 'adapter_is_mention'
    }
  ]
}

async function findRoomById(id: string): Promise<ExternalGatewayChannel | undefined> {
  const rows = await DB.select().from(ExternalRooms).where(eq(ExternalRooms.id, id)).limit(1)
  return rows[0]
}

function ensureNonEmpty(value: string, label: string): string {
  if (value.length === 0) throw new ExternalGatewayProjectionError(`${label} must not be empty`)

  return value
}

class ExternalGatewayProjectionError extends Error {
  constructor(message: string) {
    super(message)
    this.name = 'ExternalGatewayProjectionError'
  }
}
