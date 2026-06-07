import { sql } from 'drizzle-orm'
import { check, index, integer, jsonb, numeric, pgTable, text, timestamp, uniqueIndex, uuid } from 'drizzle-orm/pg-core'
import { Agents, type JsonObject, type JsonValue } from './principals'

export type AiAgentConversationGeneration = JsonObject & {
  lease_id?: string
  trigger_message_id?: string
  trigger_event_id?: string
  started_at?: string
  heartbeat_at?: string
  expires_at?: string
  max_expires_at?: string
  cancelled_at?: string | null
  cancellation_reason?: string | null
  cancelled_by_event_id?: string | null
  pending_followups?: JsonValue[]
  pending_steering?: JsonValue[]
}

export const AiAgentConversations = pgTable(
  'ai_agent_conversations',
  {
    id: uuid('id').primaryKey().notNull(),
    agentUid: text('agent_uid')
      .notNull()
      .references(() => Agents.uid, { onDelete: 'restrict' }),
    conversationKey: text('conversation_key').notNull(),
    endedAt: timestamp('ended_at', { withTimezone: true }),
    generation: jsonb('generation').$type<AiAgentConversationGeneration>().default({}).notNull(),
    metadata: jsonb('metadata').$type<JsonObject>().default({}).notNull(),
    createdAt: timestamp('created_at', { withTimezone: true })
      .default(sql`now()`)
      .notNull(),
    updatedAt: timestamp('updated_at', { withTimezone: true })
      .default(sql`now()`)
      .notNull()
  },
  t => [
    uniqueIndex('ai_agent_conversations_active_key_index')
      .on(t.agentUid, t.conversationKey)
      .where(sql`${t.endedAt} IS NULL`),
    index('ai_agent_conversations_stale_generation_index').on(t.endedAt, t.updatedAt),
    check('ai_agent_conversations_key_nonempty', sql`${t.conversationKey} <> ''`),
    check('ai_agent_conversations_generation_object', sql`jsonb_typeof(${t.generation}) = 'object'`),
    check('ai_agent_conversations_metadata_object', sql`jsonb_typeof(${t.metadata}) = 'object'`)
  ]
)

export const AiAgentMessages = pgTable(
  'ai_agent_messages',
  {
    id: uuid('id').primaryKey().notNull(),
    agentUid: text('agent_uid').notNull(),
    conversationId: uuid('conversation_id')
      .notNull()
      .references(() => AiAgentConversations.id, { onDelete: 'cascade' }),
    role: text('role').notNull(),
    kind: text('kind').default('normal').notNull(),
    status: text('status').default('complete').notNull(),
    content: jsonb('content').$type<JsonValue[]>().default([]).notNull(),
    agentMessage: jsonb('agent_message').$type<JsonObject | null>(),
    coversRange: jsonb('covers_range').$type<JsonObject | null>(),
    eventSource: text('event_source'),
    eventId: text('event_id'),
    metadata: jsonb('metadata').$type<JsonObject>().default({}).notNull(),
    createdAt: timestamp('created_at', { withTimezone: true })
      .default(sql`now()`)
      .notNull(),
    updatedAt: timestamp('updated_at', { withTimezone: true })
      .default(sql`now()`)
      .notNull()
  },
  t => [
    index('ai_agent_messages_conversation_order_index').on(t.conversationId, t.createdAt, t.id),
    uniqueIndex('ai_agent_messages_inbound_event_index')
      .on(t.conversationId, t.eventSource, t.eventId)
      .where(sql`${t.role} in ('user', 'im_ambient') and ${t.kind} = 'normal' and ${t.eventSource} is not null and ${t.eventId} is not null`),
    index('ai_agent_messages_summary_index')
      .on(t.conversationId, t.createdAt, t.id)
      .where(sql`${t.kind} = 'summary' and ${t.status} = 'complete'`),
    index('ai_agent_messages_assistant_index')
      .on(t.conversationId, t.createdAt, t.id)
      .where(sql`${t.role} = 'assistant'`),
    index('ai_agent_messages_provider_message_ids_index')
      .using('gin', sql`${t.metadata}->'provider_refs'->'message_ids'`)
      .where(sql`${t.role} in ('user', 'im_ambient') and ${t.kind} = 'normal'`),
    check('ai_agent_messages_role_check', sql`${t.role} in ('user', 'assistant', 'tool', 'im_ambient')`),
    check('ai_agent_messages_kind_check', sql`${t.kind} in ('normal', 'summary', 'introspection', 'error')`),
    check('ai_agent_messages_status_check', sql`${t.status} in ('generating', 'complete')`),
    check('ai_agent_messages_content_array', sql`jsonb_typeof(${t.content}) = 'array'`),
    check('ai_agent_messages_metadata_object', sql`jsonb_typeof(${t.metadata}) = 'object'`)
  ]
)

export const AiAgentLlmTurns = pgTable(
  'ai_agent_llm_turns',
  {
    id: uuid('id').primaryKey().notNull(),
    agentUid: text('agent_uid').notNull(),
    conversationId: uuid('conversation_id')
      .notNull()
      .references(() => AiAgentConversations.id, { onDelete: 'cascade' }),
    kind: text('kind').notNull(),
    status: text('status').default('started').notNull(),
    profile: text('profile').notNull(),
    provider: text('provider').notNull(),
    model: text('model').notNull(),
    reasoning: text('reasoning'),
    temperature: numeric('temperature'),
    maxTokens: integer('max_tokens'),
    cacheRetention: text('cache_retention'),
    triggerMessageId: uuid('trigger_message_id'),
    triggerEventId: text('trigger_event_id'),
    inputMessageIds: jsonb('input_message_ids').$type<JsonValue[]>().default([]).notNull(),
    inputSummaryMessageId: uuid('input_summary_message_id'),
    requestContext: jsonb('request_context').$type<JsonObject>().default({}).notNull(),
    response: jsonb('response').$type<JsonObject>().default({}).notNull(),
    usage: jsonb('usage').$type<JsonObject>().default({}).notNull(),
    providerMetadata: jsonb('provider_metadata').$type<JsonObject>().default({}).notNull(),
    startedAt: timestamp('started_at', { withTimezone: true })
      .default(sql`now()`)
      .notNull(),
    completedAt: timestamp('completed_at', { withTimezone: true }),
    createdAt: timestamp('created_at', { withTimezone: true })
      .default(sql`now()`)
      .notNull(),
    updatedAt: timestamp('updated_at', { withTimezone: true })
      .default(sql`now()`)
      .notNull()
  },
  t => [
    index('ai_agent_llm_turns_conversation_index').on(t.conversationId, t.startedAt, t.id),
    index('ai_agent_llm_turns_trigger_index').on(t.triggerMessageId),
    check(
      'ai_agent_llm_turns_kind_check',
      sql`${t.kind} in ('generation', 'retry_generation', 'compression', 'ambient_recognizer', 'overflow_retry')`
    ),
    check('ai_agent_llm_turns_status_check', sql`${t.status} in ('started', 'succeeded', 'failed', 'cancelled')`),
    check('ai_agent_llm_turns_profile_check', sql`${t.profile} in ('primary', 'light', 'heavy')`),
    check('ai_agent_llm_turns_input_message_ids_array', sql`jsonb_typeof(${t.inputMessageIds}) = 'array'`),
    check('ai_agent_llm_turns_request_context_object', sql`jsonb_typeof(${t.requestContext}) = 'object'`),
    check('ai_agent_llm_turns_response_object', sql`jsonb_typeof(${t.response}) = 'object'`),
    check('ai_agent_llm_turns_usage_object', sql`jsonb_typeof(${t.usage}) = 'object'`),
    check('ai_agent_llm_turns_provider_metadata_object', sql`jsonb_typeof(${t.providerMetadata}) = 'object'`)
  ]
)
