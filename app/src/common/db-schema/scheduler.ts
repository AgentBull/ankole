import { sql } from 'drizzle-orm'
import { boolean, check, index, integer, jsonb, pgTable, text, timestamp, uniqueIndex, uuid } from 'drizzle-orm/pg-core'
import { Agents, type JsonObject } from './principals'
import type { JsonValue } from './principals'
import { AiAgentConversations, AiAgentMessages } from './ai-agent'

export type SchedulerRunStatus = 'running' | 'succeeded' | 'failed' | 'cancelled'

export type ScheduledTaskSchedule =
  | {
      anchor_ms?: number
      every_ms: number
      kind: 'every'
    }
  | {
      expression: string
      kind: 'cron'
      stagger_ms?: number
    }

export interface ScheduledTaskPayload extends JsonObject {
  message: string
}

export interface ScheduledTaskDelivery extends JsonObject {
  binding_name: string
  room_id: string
  thread_id: string | null
}

export const ScheduledTasks = pgTable(
  'scheduled_tasks',
  {
    id: uuid('id').primaryKey().notNull(),
    agentUid: text('agent_uid')
      .notNull()
      .references(() => Agents.uid, { onDelete: 'cascade' }),
    name: text('name').notNull(),
    enabled: boolean('enabled').default(true).notNull(),
    schedule: jsonb('schedule').$type<ScheduledTaskSchedule>().notNull(),
    payload: jsonb('payload').$type<ScheduledTaskPayload>().notNull(),
    delivery: jsonb('delivery').$type<ScheduledTaskDelivery | null>(),
    nextRunAt: timestamp('next_run_at', { withTimezone: true }),
    lastRunAt: timestamp('last_run_at', { withTimezone: true }),
    previousRunAt: timestamp('previous_run_at', { withTimezone: true }),
    lastStatus: text('last_status'),
    lastRunId: uuid('last_run_id'),
    consecutiveFailures: integer('consecutive_failures').default(0).notNull(),
    lastAlertAt: timestamp('last_alert_at', { withTimezone: true }),
    claimedBy: text('claimed_by'),
    claimedAt: timestamp('claimed_at', { withTimezone: true }),
    leaseExpiresAt: timestamp('lease_expires_at', { withTimezone: true }),
    createdAt: timestamp('created_at', { withTimezone: true })
      .default(sql`now()`)
      .notNull(),
    updatedAt: timestamp('updated_at', { withTimezone: true })
      .default(sql`now()`)
      .notNull()
  },
  t => [
    uniqueIndex('scheduled_tasks_agent_name_index').on(t.agentUid, t.name),
    index('scheduled_tasks_due_index').on(t.enabled, t.nextRunAt),
    index('scheduled_tasks_lease_index').on(t.leaseExpiresAt),
    check('scheduled_tasks_name_nonempty', sql`${t.name} <> ''`),
    check('scheduled_tasks_schedule_object', sql`jsonb_typeof(${t.schedule}) = 'object'`),
    check('scheduled_tasks_payload_object', sql`jsonb_typeof(${t.payload}) = 'object'`),
    check('scheduled_tasks_schedule_kind', sql`${t.schedule}->>'kind' in ('every', 'cron')`),
    check('scheduled_tasks_delivery_object', sql`${t.delivery} is null or jsonb_typeof(${t.delivery}) = 'object'`),
    check('scheduled_tasks_failures_nonnegative', sql`${t.consecutiveFailures} >= 0`),
    check(
      'scheduled_tasks_last_status_check',
      sql`${t.lastStatus} is null or ${t.lastStatus} in ('succeeded', 'failed', 'cancelled')`
    )
  ]
)

export const ScheduledTaskRuns = pgTable(
  'scheduled_task_runs',
  {
    id: uuid('id').primaryKey().notNull(),
    taskId: uuid('task_id')
      .notNull()
      .references(() => ScheduledTasks.id, { onDelete: 'cascade' }),
    agentUid: text('agent_uid').notNull(),
    scheduledFor: timestamp('scheduled_for', { withTimezone: true }).notNull(),
    startedAt: timestamp('started_at', { withTimezone: true })
      .default(sql`now()`)
      .notNull(),
    finishedAt: timestamp('finished_at', { withTimezone: true }),
    status: text('status').default('running').notNull(),
    trigger: text('trigger').default('schedule').notNull(),
    conversationId: uuid('conversation_id').references(() => AiAgentConversations.id, { onDelete: 'set null' }),
    triggerMessageId: uuid('trigger_message_id').references(() => AiAgentMessages.id, { onDelete: 'set null' }),
    runByInstance: text('run_by_instance'),
    delivered: boolean('delivered').default(false).notNull(),
    error: text('error'),
    metadata: jsonb('metadata').$type<JsonObject>().default({}).notNull(),
    createdAt: timestamp('created_at', { withTimezone: true })
      .default(sql`now()`)
      .notNull(),
    updatedAt: timestamp('updated_at', { withTimezone: true })
      .default(sql`now()`)
      .notNull()
  },
  t => [
    index('scheduled_task_runs_task_index').on(t.taskId, t.startedAt),
    check('scheduled_task_runs_status_check', sql`${t.status} in ('running', 'succeeded', 'failed', 'cancelled')`),
    check('scheduled_task_runs_trigger_check', sql`${t.trigger} in ('schedule', 'manual', 'catchup')`),
    check('scheduled_task_runs_metadata_object', sql`jsonb_typeof(${t.metadata}) = 'object'`)
  ]
)

export type AiAgentCheckbackStatus = 'pending' | 'running' | 'succeeded' | 'failed' | 'cancelled'

export interface AiAgentCheckbackSource extends JsonObject {
  binding_name: string
  conversation_id: string
  lease_id: string
  provider_realm_id: string | null
  provider_room_id: string | null
  provider_thread_id: string | null
  trigger_message_id: string
  tool_call_id: string
}

export const AiAgentCheckbacks = pgTable(
  'ai_agent_checkbacks',
  {
    id: uuid('id').primaryKey().notNull(),
    agentUid: text('agent_uid')
      .notNull()
      .references(() => Agents.uid, { onDelete: 'cascade' }),
    dueAt: timestamp('due_at', { withTimezone: true }).notNull(),
    timezone: text('timezone').notNull(),
    status: text('status').default('pending').notNull(),
    reason: text('reason').notNull(),
    check: text('check').notNull(),
    contextSummary: text('context_summary'),
    source: jsonb('source').$type<AiAgentCheckbackSource>().notNull(),
    wakeMessage: jsonb('wake_message').$type<JsonValue[]>().default([]).notNull(),
    conversationId: uuid('conversation_id').references(() => AiAgentConversations.id, { onDelete: 'set null' }),
    triggerMessageId: uuid('trigger_message_id').references(() => AiAgentMessages.id, { onDelete: 'set null' }),
    completedAt: timestamp('completed_at', { withTimezone: true }),
    claimedBy: text('claimed_by'),
    claimedAt: timestamp('claimed_at', { withTimezone: true }),
    leaseExpiresAt: timestamp('lease_expires_at', { withTimezone: true }),
    error: text('error'),
    metadata: jsonb('metadata').$type<JsonObject>().default({}).notNull(),
    createdAt: timestamp('created_at', { withTimezone: true })
      .default(sql`now()`)
      .notNull(),
    updatedAt: timestamp('updated_at', { withTimezone: true })
      .default(sql`now()`)
      .notNull()
  },
  t => [
    index('ai_agent_checkbacks_due_index').on(t.status, t.dueAt),
    index('ai_agent_checkbacks_agent_index').on(t.agentUid, t.createdAt),
    index('ai_agent_checkbacks_lease_index').on(t.leaseExpiresAt),
    check(
      'ai_agent_checkbacks_status_check',
      sql`${t.status} in ('pending', 'running', 'succeeded', 'failed', 'cancelled')`
    ),
    check('ai_agent_checkbacks_timezone_nonempty', sql`${t.timezone} <> ''`),
    check('ai_agent_checkbacks_reason_nonempty', sql`${t.reason} <> ''`),
    check('ai_agent_checkbacks_check_nonempty', sql`${t.check} <> ''`),
    check('ai_agent_checkbacks_source_object', sql`jsonb_typeof(${t.source}) = 'object'`),
    check('ai_agent_checkbacks_wake_message_array', sql`jsonb_typeof(${t.wakeMessage}) = 'array'`),
    check('ai_agent_checkbacks_metadata_object', sql`jsonb_typeof(${t.metadata}) = 'object'`)
  ]
)
