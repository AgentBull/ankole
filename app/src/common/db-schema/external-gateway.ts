import { sql } from 'drizzle-orm'
import {
  boolean,
  check,
  customType,
  index,
  integer,
  jsonb,
  pgTable,
  primaryKey,
  text,
  timestamp,
  uniqueIndex,
  uuid
} from 'drizzle-orm/pg-core'
import type { JsonObject, JsonValue } from './principals'
import { Agents, Principals } from './principals'

const pgVector = customType<{ data: number[] | null; driverData: string | null }>({
  dataType() {
    return 'vector'
  }
})

/**
 * Latest known visible state of one upstream external room.
 *
 * `id` is the normalized external room id exposed by the adapter. Agent uid,
 * local adapter factory id, binding name, and platform implementation details
 * are observation context, not first-class projection identity.
 */
export const ExternalRooms = pgTable(
  'external_rooms',
  {
    id: text('id').primaryKey().notNull(),
    isDM: boolean('is_dm').default(false).notNull(),
    roomVisibility: text('room_visibility').default('unknown').notNull(),
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
    check('external_rooms_id_nonempty', sql`${t.id} <> ''`),
    check('external_rooms_metadata_object', sql`jsonb_typeof(${t.metadata}) = 'object'`)
  ]
)

/**
 * Latest known visible state of one upstream external message.
 *
 * A message belongs to one projected room (`room_id`) and is identified inside
 * that room by the provider-visible message id. Operational provider thread
 * scope stays in gateway input/outbox tables because it is needed for batching
 * and channel delivery, but it is not extra projection identity. Deletes and
 * recalls hard-delete it. Inbound edit events are not part of the current
 * External Gateway contract.
 *
 * This table is a projection consumer of External Gateway, not Gateway queue
 * state. Platform-specific card or event payloads stay in `raw` unless the
 * adapter exposes a stable normalized field for them.
 */
export const ExternalMessages = pgTable(
  'external_messages',
  {
    documentId: uuid('document_id')
      .default(sql`gen_random_uuid()`)
      .notNull(),
    roomId: text('room_id')
      .notNull()
      .references(() => ExternalRooms.id, { onDelete: 'cascade' }),
    messageId: text('message_id').notNull(),
    authorId: text('author_id'),
    userKey: text('user_key'),
    author: jsonb('author').$type<JsonObject>().default({}).notNull(),
    mentions: jsonb('mentions').$type<JsonValue[]>().default([]).notNull(),
    text: text('text'),
    formatted: jsonb('formatted').$type<JsonObject>().default({}).notNull(),
    attachments: jsonb('attachments').$type<JsonValue[]>().default([]).notNull(),
    links: jsonb('links').$type<JsonValue[]>().default([]).notNull(),
    metadata: jsonb('metadata').$type<JsonObject>().default({}).notNull(),
    reactions: jsonb('reactions').$type<JsonObject>().default({}).notNull(),
    raw: jsonb('raw').$type<JsonValue>(),
    searchText: text('search_text').default('').notNull(),
    metadataText: text('metadata_text').default('').notNull(),
    contentHash: text('content_hash').default('').notNull(),
    sentAt: timestamp('sent_at', { withTimezone: true }),
    createdAt: timestamp('created_at', { withTimezone: true })
      .default(sql`now()`)
      .notNull(),
    updatedAt: timestamp('updated_at', { withTimezone: true })
      .default(sql`now()`)
      .notNull()
  },
  t => [
    primaryKey({ name: 'external_messages_pkey', columns: [t.roomId, t.messageId] }),
    uniqueIndex('external_messages_document_id_index').on(t.documentId),
    index('external_messages_room_id_sent_at_index').on(t.roomId, t.sentAt),
    check('external_messages_message_id_nonempty', sql`${t.messageId} <> ''`),
    check('external_messages_author_object', sql`jsonb_typeof(${t.author}) = 'object'`),
    check('external_messages_mentions_array', sql`jsonb_typeof(${t.mentions}) = 'array'`),
    check('external_messages_formatted_object', sql`jsonb_typeof(${t.formatted}) = 'object'`),
    check('external_messages_attachments_array', sql`jsonb_typeof(${t.attachments}) = 'array'`),
    check('external_messages_links_array', sql`jsonb_typeof(${t.links}) = 'array'`),
    check('external_messages_metadata_object', sql`jsonb_typeof(${t.metadata}) = 'object'`),
    check('external_messages_reactions_object', sql`jsonb_typeof(${t.reactions}) = 'object'`)
  ]
)

/**
 * Embedding state for chat history recall.
 *
 * `external_messages.document_id` is the stable pg_search key and embedding
 * identity. Each embedding profile gets its own row so model/profile switches
 * can re-embed without rewriting the canonical external message mirror.
 */
export const ChatRecallEmbeddings = pgTable(
  'chat_recall_embeddings',
  {
    documentId: uuid('document_id')
      .notNull()
      .references(() => ExternalMessages.documentId, { onDelete: 'cascade' }),
    profileId: text('profile_id').notNull(),
    providerKind: text('provider_kind').notNull(),
    providerId: text('provider_id').notNull(),
    model: text('model').notNull(),
    dimensions: integer('dimensions').default(0).notNull(),
    embedding: pgVector('embedding'),
    contentHash: text('content_hash').notNull(),
    status: text('status').default('pending').notNull(),
    attemptCount: integer('attempt_count').default(0).notNull(),
    nextRetryAt: timestamp('next_retry_at', { withTimezone: true })
      .default(sql`now()`)
      .notNull(),
    lockedAt: timestamp('locked_at', { withTimezone: true }),
    lastError: text('last_error'),
    createdAt: timestamp('created_at', { withTimezone: true })
      .default(sql`now()`)
      .notNull(),
    updatedAt: timestamp('updated_at', { withTimezone: true })
      .default(sql`now()`)
      .notNull()
  },
  t => [
    primaryKey({ name: 'chat_recall_embeddings_pkey', columns: [t.documentId, t.profileId] }),
    index('chat_recall_embeddings_ready_idx').on(t.status, t.nextRetryAt, t.updatedAt),
    index('chat_recall_embeddings_profile_status_idx').on(t.profileId, t.status, t.dimensions),
    check('chat_recall_embeddings_dimensions_check', sql`${t.dimensions} >= 0`),
    check('chat_recall_embeddings_status_check', sql`${t.status} in ('pending', 'processing', 'synced', 'failed')`)
  ]
)

/**
 * Observed human membership in an external room.
 *
 * V1 records members when a trusted platform subject is observed sending a
 * message. Lark full/incremental group member sync can later upsert the same
 * table to cover silent members.
 */
export const ExternalRoomMemberships = pgTable(
  'external_room_memberships',
  {
    roomId: text('room_id')
      .notNull()
      .references(() => ExternalRooms.id, { onDelete: 'cascade' }),
    principalUid: text('principal_uid')
      .notNull()
      .references(() => Principals.uid, { onDelete: 'cascade' }),
    externalId: text('external_id'),
    source: text('source').default('message_author').notNull(),
    metadata: jsonb('metadata').$type<JsonObject>().default({}).notNull(),
    observedAt: timestamp('observed_at', { withTimezone: true })
      .default(sql`now()`)
      .notNull(),
    createdAt: timestamp('created_at', { withTimezone: true })
      .default(sql`now()`)
      .notNull(),
    updatedAt: timestamp('updated_at', { withTimezone: true })
      .default(sql`now()`)
      .notNull()
  },
  t => [
    primaryKey({ name: 'external_room_memberships_pkey', columns: [t.roomId, t.principalUid] }),
    index('external_room_memberships_principal_uid_index').on(t.principalUid),
    check('external_room_memberships_metadata_object', sql`jsonb_typeof(${t.metadata}) = 'object'`)
  ]
)

/**
 * Agent/binding visibility of external rooms.
 *
 * A group room is in recall scope only when the requesting human is a member
 * and the agent has observed that room through one of its enabled bindings.
 */
export const ExternalAgentRoomObservations = pgTable(
  'external_agent_room_observations',
  {
    agentUid: text('agent_uid')
      .notNull()
      .references(() => Agents.uid, { onDelete: 'cascade' }),
    bindingName: text('binding_name').notNull(),
    roomId: text('room_id')
      .notNull()
      .references(() => ExternalRooms.id, { onDelete: 'cascade' }),
    metadata: jsonb('metadata').$type<JsonObject>().default({}).notNull(),
    observedAt: timestamp('observed_at', { withTimezone: true })
      .default(sql`now()`)
      .notNull(),
    createdAt: timestamp('created_at', { withTimezone: true })
      .default(sql`now()`)
      .notNull(),
    updatedAt: timestamp('updated_at', { withTimezone: true })
      .default(sql`now()`)
      .notNull()
  },
  t => [
    primaryKey({
      name: 'external_agent_room_observations_pkey',
      columns: [t.agentUid, t.bindingName, t.roomId]
    }),
    index('external_agent_room_observations_room_id_index').on(t.roomId),
    check('external_agent_room_observations_metadata_object', sql`jsonb_typeof(${t.metadata}) = 'object'`)
  ]
)

/**
 * Operational input window from External Gateway to the owning agent.
 *
 * This is not an audit log and not a durable lease queue. PostgreSQL owns the
 * accepted pending facts; the running gateway process owns short-lived in-flight
 * work. A crash before completion leaves the pending row available on restart,
 * while handler failures are terminal runtime facts rather than automatic
 * retries.
 */
export const ExternalGatewayAgentEvents = pgTable(
  'external_gateway_agent_events',
  {
    agentUid: text('agent_uid').notNull(),
    bindingName: text('binding_name').notNull(),
    providerRoomId: text('provider_room_id').notNull(),
    providerThreadId: text('provider_thread_id').notNull(),
    providerEventId: text('provider_event_id').notNull(),
    providerMessageId: text('provider_message_id'),
    type: text('type').notNull(),
    deliveryMode: text('delivery_mode').notNull(),
    batchKey: text('batch_key'),
    actorKey: text('actor_key'),
    payload: jsonb('payload').$type<JsonObject>().default({}).notNull(),
    status: text('status').default('pending').notNull(),
    availableAt: timestamp('available_at', { withTimezone: true })
      .default(sql`now()`)
      .notNull(),
    createdAt: timestamp('created_at', { withTimezone: true })
      .default(sql`now()`)
      .notNull(),
    updatedAt: timestamp('updated_at', { withTimezone: true })
      .default(sql`now()`)
      .notNull()
  },
  t => [
    primaryKey({
      name: 'external_gateway_agent_events_pkey',
      columns: [t.agentUid, t.bindingName, t.providerEventId]
    }),
    index('external_gateway_agent_events_ready_index').on(t.status, t.availableAt),
    index('external_gateway_agent_events_batch_index').on(t.agentUid, t.batchKey, t.status, t.createdAt),
    check('external_gateway_agent_events_payload_object', sql`jsonb_typeof(${t.payload}) = 'object'`),
    check('external_gateway_agent_events_status_check', sql`${t.status} in ('pending', 'done', 'failed')`),
    check(
      'external_gateway_agent_events_delivery_mode_check',
      sql`${t.deliveryMode} in ('addressed', 'ambient', 'command', 'action', 'lifecycle')`
    )
  ]
)

/**
 * Short-lived operational tombstones for delete/recall events that can arrive
 * before the corresponding receive event.
 *
 * This is part of the input window, not audit history. A tombstone prevents a
 * stale late receive from re-projecting a provider-visible message that was
 * already removed.
 */
export const ExternalGatewayInputTombstones = pgTable(
  'external_gateway_input_tombstones',
  {
    agentUid: text('agent_uid').notNull(),
    bindingName: text('binding_name').notNull(),
    providerRoomId: text('provider_room_id').notNull(),
    providerMessageId: text('provider_message_id').notNull(),
    expiresAt: timestamp('expires_at', { withTimezone: true }).notNull(),
    createdAt: timestamp('created_at', { withTimezone: true })
      .default(sql`now()`)
      .notNull(),
    updatedAt: timestamp('updated_at', { withTimezone: true })
      .default(sql`now()`)
      .notNull()
  },
  t => [
    primaryKey({
      name: 'external_gateway_input_tombstones_pkey',
      columns: [t.agentUid, t.bindingName, t.providerRoomId, t.providerMessageId]
    }),
    index('external_gateway_input_tombstones_expires_at_index').on(t.expiresAt)
  ]
)

/**
 * Provider-visible final side effects requested by an agent.
 *
 * Streaming deltas are deliberately excluded. Projection only updates after the
 * adapter confirms a visible provider success.
 */
export const ExternalGatewayOutbox = pgTable(
  'external_gateway_outbox',
  {
    agentUid: text('agent_uid').notNull(),
    bindingName: text('binding_name').notNull(),
    providerRoomId: text('provider_room_id').notNull(),
    providerThreadId: text('provider_thread_id').notNull(),
    outboundKey: text('outbound_key').notNull(),
    operation: text('operation').notNull(),
    finalPayload: jsonb('final_payload').$type<JsonObject>().default({}).notNull(),
    status: text('status').default('pending').notNull(),
    providerMessageId: text('provider_message_id'),
    idempotencyKey: text('idempotency_key'),
    retryCount: integer('retry_count').default(0).notNull(),
    lastAttemptAt: timestamp('last_attempt_at', { withTimezone: true }),
    lastError: text('last_error'),
    platformSendStartedAt: timestamp('platform_send_started_at', { withTimezone: true }),
    recoveryState: text('recovery_state').default('not_started').notNull(),
    safeError: text('safe_error'),
    createdAt: timestamp('created_at', { withTimezone: true })
      .default(sql`now()`)
      .notNull(),
    updatedAt: timestamp('updated_at', { withTimezone: true })
      .default(sql`now()`)
      .notNull()
  },
  t => [
    primaryKey({
      name: 'external_gateway_outbox_pkey',
      columns: [t.agentUid, t.bindingName, t.outboundKey]
    }),
    index('external_gateway_outbox_status_index').on(t.status, t.createdAt),
    index('external_gateway_outbox_binding_pending_index').on(t.agentUid, t.bindingName, t.status, t.createdAt),
    check('external_gateway_outbox_final_payload_object', sql`jsonb_typeof(${t.finalPayload}) = 'object'`),
    check('external_gateway_outbox_status_check', sql`${t.status} in ('pending', 'sent', 'failed', 'unsupported')`),
    check(
      'external_gateway_outbox_recovery_state_check',
      sql`${t.recoveryState} in ('not_started', 'send_attempt_started', 'unknown_after_send')`
    ),
    check(
      'external_gateway_outbox_operation_check',
      sql`${t.operation} in ('post', 'reply', 'edit', 'delete', 'reaction_add', 'reaction_remove', 'modal', 'card', 'divider')`
    )
  ]
)
