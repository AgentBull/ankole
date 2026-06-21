import { sql } from 'drizzle-orm'
import { boolean, check, index, integer, jsonb, pgTable, text, timestamp, uniqueIndex, uuid } from 'drizzle-orm/pg-core'
import { Agents, type JsonObject } from './principals'
import type { JsonValue } from './principals'
import { AiAgentConversations, AiAgentMessages } from './ai-agent'

export type SchedulerRunStatus = 'running' | 'succeeded' | 'failed' | 'cancelled'

/**
 * Discriminated union (on `kind`) for the JSONB `schedule` column.
 *
 * `every`: fixed interval; `anchor_ms` optionally phases the interval so runs
 * land at a chosen offset rather than relative to creation time. `cron`: a cron
 * expression, with `stagger_ms` spreading otherwise-simultaneous fires across
 * tasks to avoid a thundering herd at common boundaries (top of the hour, etc.).
 */
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

/** Shape of the JSONB `payload`: the message handed to the agent when the task fires. */
export interface ScheduledTaskPayload extends JsonObject {
  message: string
}

/**
 * Shape of the JSONB `delivery`: where a task's output goes. Null thread_id means
 * the room itself rather than a specific thread. Absent entirely (column null)
 * means no external delivery is bound.
 */
export interface ScheduledTaskDelivery extends JsonObject {
  binding_name: string
  room_id: string
  thread_id: string | null
}

/**
 * A recurring task an agent runs on a schedule (one row per task definition).
 *
 * The row is the durable definition plus its running state: when it next fires,
 * how the last run went, and which scheduler instance currently holds it. It
 * lives until the task is deleted; individual executions are recorded separately
 * in {@link ScheduledTaskRuns}.
 */
export const ScheduledTasks = pgTable(
  'scheduled_tasks',
  {
    id: uuid('id').primaryKey().notNull(),
    agentUid: text('agent_uid')
      .notNull()
      .references(() => Agents.uid, { onDelete: 'cascade' }),
    name: text('name').notNull(),
    // Pause switch: a disabled task keeps its definition and history but is not
    // picked up by the due-scan.
    enabled: boolean('enabled').default(true).notNull(),
    schedule: jsonb('schedule').$type<ScheduledTaskSchedule>().notNull(),
    payload: jsonb('payload').$type<ScheduledTaskPayload>().notNull(),
    delivery: jsonb('delivery').$type<ScheduledTaskDelivery | null>(),
    // The scheduler's clock for this task: when it is next eligible to run. Null
    // means nothing scheduled (e.g. disabled or fully consumed).
    nextRunAt: timestamp('next_run_at', { withTimezone: true }),
    // last_run_at is the most recent fire; previous_run_at is the one before it,
    // kept so an interval can be computed even right after a run starts.
    lastRunAt: timestamp('last_run_at', { withTimezone: true }),
    previousRunAt: timestamp('previous_run_at', { withTimezone: true }),
    // Denormalized outcome of the most recent run (mirrors that run's status),
    // so the due-scan and alerting can read health without joining the runs table.
    lastStatus: text('last_status'),
    lastRunId: uuid('last_run_id'),
    // Failure streak driving alerting; reset to 0 on success.
    consecutiveFailures: integer('consecutive_failures').default(0).notNull(),
    // Last time a failure alert fired, used to rate-limit repeat alerts.
    lastAlertAt: timestamp('last_alert_at', { withTimezone: true }),
    // Lease fields: the instance that has claimed this task, when, and until when.
    // A task whose lease has expired can be re-claimed by another instance after a
    // crash — the lease, not row existence, is the ownership token.
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
    // Task names are unique per agent, so a task can be addressed by (agent, name).
    uniqueIndex('scheduled_tasks_agent_name_index').on(t.agentUid, t.name),
    // Hot path: the due-scan filters enabled tasks ordered by next_run_at to find
    // what to fire now.
    index('scheduled_tasks_due_index').on(t.enabled, t.nextRunAt),
    // Lets a recovery sweep find leases that have expired and are safe to re-claim.
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

/**
 * One execution of a scheduled task (append-only history).
 *
 * Created when a run starts and finalized when it ends. `scheduled_for` is the
 * slot the run was meant to cover (which can differ from `started_at` for a late
 * catch-up), so missed-slot accounting stays accurate.
 */
export const ScheduledTaskRuns = pgTable(
  'scheduled_task_runs',
  {
    id: uuid('id').primaryKey().notNull(),
    taskId: uuid('task_id')
      .notNull()
      .references(() => ScheduledTasks.id, { onDelete: 'cascade' }),
    agentUid: text('agent_uid').notNull(),
    // Intended slot time vs actual start; the gap reveals lateness/catch-up.
    scheduledFor: timestamp('scheduled_for', { withTimezone: true }).notNull(),
    startedAt: timestamp('started_at', { withTimezone: true })
      .default(sql`now()`)
      .notNull(),
    finishedAt: timestamp('finished_at', { withTimezone: true }),
    status: text('status').default('running').notNull(),
    // How the run was initiated: 'schedule' (normal fire), 'manual' (operator
    // run-now), or 'catchup' (filling a slot missed while the scheduler was down).
    trigger: text('trigger').default('schedule').notNull(),
    // Links to the conversation/message the run produced. `set null` on delete so
    // pruning conversation history does not delete run history.
    conversationId: uuid('conversation_id').references(() => AiAgentConversations.id, { onDelete: 'set null' }),
    triggerMessageId: uuid('trigger_message_id').references(() => AiAgentMessages.id, { onDelete: 'set null' }),
    // Which scheduler instance executed this run, for diagnostics.
    runByInstance: text('run_by_instance'),
    // Whether the result was delivered to the configured destination; lets a
    // delivery retry distinguish "ran but not delivered" from "not run".
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
    index('scheduled_task_runs_conversation_index').on(t.conversationId),
    index('scheduled_task_runs_trigger_message_index').on(t.triggerMessageId),
    check('scheduled_task_runs_status_check', sql`${t.status} in ('running', 'succeeded', 'failed', 'cancelled')`),
    check('scheduled_task_runs_trigger_check', sql`${t.trigger} in ('schedule', 'manual', 'catchup')`),
    check('scheduled_task_runs_metadata_object', sql`jsonb_typeof(${t.metadata}) = 'object'`)
  ]
)

export type AiAgentCheckbackStatus = 'pending' | 'running' | 'succeeded' | 'failed' | 'cancelled'

/**
 * Shape of the JSONB `source`: where the checkback originated.
 *
 * Captures the exact tool call and conversation context (down to lease and
 * provider room/thread) that scheduled the checkback, so that when it later
 * wakes the agent the run is resumed in the same conversation it came from rather
 * than a detached one. Provider fields are nullable because not every origin is
 * bound to an external room.
 */
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

/**
 * A self-scheduled "check back later" the agent sets for itself (one row per
 * checkback).
 *
 * When the agent decides something needs revisiting at a future time (e.g. "see
 * if the deploy finished in 30 min"), it records a checkback. At `due_at` the
 * scheduler wakes the agent, in the originating conversation (see
 * {@link AiAgentCheckbackSource}), with `wake_message` as the prompt. The row is
 * claimed via the same lease pattern as scheduled tasks and is terminal once it
 * succeeds/fails/cancels.
 */
export const AiAgentCheckbacks = pgTable(
  'ai_agent_checkbacks',
  {
    id: uuid('id').primaryKey().notNull(),
    agentUid: text('agent_uid')
      .notNull()
      .references(() => Agents.uid, { onDelete: 'cascade' }),
    dueAt: timestamp('due_at', { withTimezone: true }).notNull(),
    // IANA timezone the checkback was reasoned about in; kept so a human-facing
    // due time stays meaningful regardless of server timezone.
    timezone: text('timezone').notNull(),
    status: text('status').default('pending').notNull(),
    // `reason`: why the agent set this. `check`: what to verify when it wakes.
    // `context_summary`: optional condensed context so the woken run does not have
    // to re-read the whole conversation.
    reason: text('reason').notNull(),
    check: text('check').notNull(),
    contextSummary: text('context_summary'),
    source: jsonb('source').$type<AiAgentCheckbackSource>().notNull(),
    // The message injected to wake the agent at due_at (content blocks).
    wakeMessage: jsonb('wake_message').$type<JsonValue[]>().default([]).notNull(),
    // `set null` on delete so pruning the origin conversation/message does not
    // delete the pending checkback.
    conversationId: uuid('conversation_id').references(() => AiAgentConversations.id, { onDelete: 'set null' }),
    triggerMessageId: uuid('trigger_message_id').references(() => AiAgentMessages.id, { onDelete: 'set null' }),
    completedAt: timestamp('completed_at', { withTimezone: true }),
    // Lease trio, same role as in scheduled_tasks: claim owner / when / expiry,
    // enabling crash-safe re-claim.
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
    // Due-scan: pending checkbacks ordered by due_at.
    index('ai_agent_checkbacks_due_index').on(t.status, t.dueAt),
    index('ai_agent_checkbacks_agent_index').on(t.agentUid, t.createdAt),
    index('ai_agent_checkbacks_conversation_index').on(t.conversationId),
    index('ai_agent_checkbacks_trigger_message_index').on(t.triggerMessageId),
    // Recovery sweep for expired leases, as in scheduled_tasks.
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
