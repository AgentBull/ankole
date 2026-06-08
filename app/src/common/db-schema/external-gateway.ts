import { sql } from 'drizzle-orm'
import { boolean, check, index, integer, jsonb, pgTable, primaryKey, text, timestamp } from 'drizzle-orm/pg-core'
import type { JsonObject, JsonValue } from './principals'

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
