import { sql } from 'drizzle-orm'
import {
  bigserial,
  boolean,
  check,
  index,
  jsonb,
  primaryKey,
  pgTable,
  text,
  timestamp,
  uniqueIndex,
  uuid
} from 'drizzle-orm/pg-core'
import type { JsonObject, JsonValue } from './principals'

/**
 * Latest known state of a Chat SDK Channel.
 *
 * `id` is Chat SDK `Channel.id` itself, not a local surrogate UUID. Agent uid,
 * local adapter factory id, webhook channel name, and platform implementation
 * details are observation context, not first-class projection identity.
 */
export const ChatChannels = pgTable(
  'chat_channels',
  {
    id: text('id').primaryKey().notNull(),
    isDM: boolean('is_dm').default(false).notNull(),
    channelVisibility: text('channel_visibility').default('unknown').notNull(),
    name: text('name'),
    metadata: jsonb('metadata').$type<JsonObject>().default({}).notNull(),
    raw: jsonb('raw').$type<JsonValue>(),
    createdAt: timestamp('created_at', { withTimezone: true })
      .default(sql`now()`)
      .notNull(),
    updatedAt: timestamp('updated_at', { withTimezone: true })
      .default(sql`now()`)
      .notNull()
  },
  t => [
    check('chat_channels_id_nonempty', sql`${t.id} <> ''`),
    check('chat_channels_metadata_object', sql`jsonb_typeof(${t.metadata}) = 'object'`)
  ]
)

/**
 * Latest known state of a Chat SDK Message.
 *
 * A message belongs to one projected Channel (`channel_id`) while retaining its
 * Chat SDK `thread_id`. That separation lets one Slack/Feishu channel contain
 * multiple external thread scopes without making those thread scopes duplicate
 * channels. Edits update the same row and set `edited_at`; deletes hard-delete
 * it.
 *
 * Columns intentionally mirror current Chat SDK `Message` fields plus the
 * local latest-state reaction map. Platform-specific card or event payloads
 * stay in `raw` unless Chat SDK exposes a stable normalized field for them.
 */
export const ChatMessages = pgTable(
  'chat_messages',
  {
    id: uuid('id').primaryKey().notNull(),
    channelId: text('channel_id')
      .notNull()
      .references(() => ChatChannels.id, { onDelete: 'cascade' }),
    threadId: text('thread_id').notNull(),
    messageId: text('message_id').notNull(),
    authorId: text('author_id'),
    userKey: text('user_key'),
    author: jsonb('author').$type<JsonObject>().default({}).notNull(),
    isMention: boolean('is_mention').default(false).notNull(),
    text: text('text'),
    formatted: jsonb('formatted').$type<JsonObject>().default({}).notNull(),
    attachments: jsonb('attachments').$type<JsonValue[]>().default([]).notNull(),
    links: jsonb('links').$type<JsonValue[]>().default([]).notNull(),
    metadata: jsonb('metadata').$type<JsonObject>().default({}).notNull(),
    reactions: jsonb('reactions').$type<JsonObject>().default({}).notNull(),
    raw: jsonb('raw').$type<JsonValue>(),
    sentAt: timestamp('sent_at', { withTimezone: true }),
    editedAt: timestamp('edited_at', { withTimezone: true }),
    createdAt: timestamp('created_at', { withTimezone: true })
      .default(sql`now()`)
      .notNull(),
    updatedAt: timestamp('updated_at', { withTimezone: true })
      .default(sql`now()`)
      .notNull()
  },
  t => [
    uniqueIndex('chat_messages_channel_id_message_id_index').on(t.channelId, t.messageId),
    index('chat_messages_channel_id_thread_id_sent_at_index').on(t.channelId, t.threadId, t.sentAt),
    check('chat_messages_thread_id_nonempty', sql`${t.threadId} <> ''`),
    check('chat_messages_message_id_nonempty', sql`${t.messageId} <> ''`),
    check('chat_messages_author_object', sql`jsonb_typeof(${t.author}) = 'object'`),
    check('chat_messages_formatted_object', sql`jsonb_typeof(${t.formatted}) = 'object'`),
    check('chat_messages_attachments_array', sql`jsonb_typeof(${t.attachments}) = 'array'`),
    check('chat_messages_links_array', sql`jsonb_typeof(${t.links}) = 'array'`),
    check('chat_messages_metadata_object', sql`jsonb_typeof(${t.metadata}) = 'object'`),
    check('chat_messages_reactions_object', sql`jsonb_typeof(${t.reactions}) = 'object'`)
  ]
)

/**
 * Durable Chat SDK thread subscriptions.
 *
 * All Chat Gateway Chat SDK state tables share `key_prefix` as their first key
 * column. Runtime instances use `bullx-agent:<agent_uid>` so two agents never
 * share subscription, lock, cache, list, or queue state by accident.
 */
export const ChatStateSubscriptions = pgTable(
  'chat_state_subscriptions',
  {
    keyPrefix: text('key_prefix').notNull(),
    threadId: text('thread_id').notNull(),
    createdAt: timestamp('created_at', { withTimezone: true })
      .default(sql`now()`)
      .notNull()
  },
  t => [primaryKey({ columns: [t.keyPrefix, t.threadId] })]
)

/**
 * Per-thread distributed lock used by Chat SDK concurrency strategies.
 */
export const ChatStateLocks = pgTable(
  'chat_state_locks',
  {
    keyPrefix: text('key_prefix').notNull(),
    threadId: text('thread_id').notNull(),
    token: text('token').notNull(),
    expiresAt: timestamp('expires_at', { withTimezone: true }).notNull(),
    updatedAt: timestamp('updated_at', { withTimezone: true })
      .default(sql`now()`)
      .notNull()
  },
  t => [primaryKey({ columns: [t.keyPrefix, t.threadId] }), index('chat_state_locks_expires_idx').on(t.expiresAt)]
)

/**
 * Generic Chat SDK key/value cache with optional TTL.
 */
export const ChatStateCache = pgTable(
  'chat_state_cache',
  {
    keyPrefix: text('key_prefix').notNull(),
    cacheKey: text('cache_key').notNull(),
    value: text('value').notNull(),
    expiresAt: timestamp('expires_at', { withTimezone: true }),
    updatedAt: timestamp('updated_at', { withTimezone: true })
      .default(sql`now()`)
      .notNull()
  },
  t => [primaryKey({ columns: [t.keyPrefix, t.cacheKey] }), index('chat_state_cache_expires_idx').on(t.expiresAt)]
)

/**
 * Append-only list primitive used by Chat SDK transcript/history helpers.
 *
 * `seq` is global enough for ordering inside a `(key_prefix, list_key)` pair;
 * callers trim by key when they need bounded history.
 */
export const ChatStateLists = pgTable(
  'chat_state_lists',
  {
    keyPrefix: text('key_prefix').notNull(),
    listKey: text('list_key').notNull(),
    seq: bigserial('seq', { mode: 'number' }).notNull(),
    value: text('value').notNull(),
    expiresAt: timestamp('expires_at', { withTimezone: true })
  },
  t => [primaryKey({ columns: [t.keyPrefix, t.listKey, t.seq] }), index('chat_state_lists_expires_idx').on(t.expiresAt)]
)

/**
 * Pending message queue used by Chat SDK `queue`, `debounce`, and `burst`
 * concurrency strategies.
 */
export const ChatStateQueues = pgTable(
  'chat_state_queues',
  {
    keyPrefix: text('key_prefix').notNull(),
    threadId: text('thread_id').notNull(),
    seq: bigserial('seq', { mode: 'number' }).notNull(),
    value: text('value').notNull(),
    expiresAt: timestamp('expires_at', { withTimezone: true }).notNull()
  },
  t => [
    primaryKey({ columns: [t.keyPrefix, t.threadId, t.seq] }),
    index('chat_state_queues_expires_idx').on(t.expiresAt)
  ]
)
