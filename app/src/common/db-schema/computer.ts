import { sql } from 'drizzle-orm'
import { index, jsonb, pgTable, text, timestamp } from 'drizzle-orm/pg-core'

type JsonObject = Record<string, unknown>

/** Registered agent computer workers (`bullx-computerd` instances). One row per stable worker id. */
export const ComputerWorkers = pgTable('computer_workers', {
  workerId: text('worker_id').primaryKey().notNull(),
  instanceId: text('instance_id').notNull(),
  baseUrl: text('base_url').notNull(),
  status: text('status').notNull().default('starting'),
  version: text('version'),
  features: jsonb('features').$type<string[]>().notNull().default([]),
  capacity: jsonb('capacity').$type<JsonObject>().notNull().default({}),
  load: jsonb('load').$type<JsonObject>().notNull().default({}),
  metadata: jsonb('metadata').$type<JsonObject>().notNull().default({}),
  registeredAt: timestamp('registered_at', { withTimezone: true })
    .notNull()
    .default(sql`now()`),
  lastHeartbeatAt: timestamp('last_heartbeat_at', { withTimezone: true })
    .notNull()
    .default(sql`now()`),
  updatedAt: timestamp('updated_at', { withTimezone: true })
    .notNull()
    .default(sql`now()`)
})

/** Explicit agent→worker pins, configured from the admin console. */
export const ComputerAgentWorkerPins = pgTable(
  'computer_agent_worker_pins',
  {
    agentUid: text('agent_uid').primaryKey().notNull(),
    workerId: text('worker_id')
      .notNull()
      .references(() => ComputerWorkers.workerId),
    reason: text('reason'),
    createdByPrincipalUid: text('created_by_principal_uid'),
    createdAt: timestamp('created_at', { withTimezone: true })
      .notNull()
      .default(sql`now()`),
    updatedAt: timestamp('updated_at', { withTimezone: true })
      .notNull()
      .default(sql`now()`)
  },
  table => [index('computer_agent_worker_pins_worker_index').on(table.workerId)]
)

/** Actual sticky agent→worker bindings produced by the resolver. */
export const ComputerAgentWorkerBindings = pgTable(
  'computer_agent_worker_bindings',
  {
    agentUid: text('agent_uid').primaryKey().notNull(),
    workerId: text('worker_id')
      .notNull()
      .references(() => ComputerWorkers.workerId),
    // explicit_pin | implicit | fallback
    bindingKind: text('binding_kind').notNull(),
    bindingReason: text('binding_reason'),
    instanceId: text('instance_id'),
    createdAt: timestamp('created_at', { withTimezone: true })
      .notNull()
      .default(sql`now()`),
    updatedAt: timestamp('updated_at', { withTimezone: true })
      .notNull()
      .default(sql`now()`),
    lastResolvedAt: timestamp('last_resolved_at', { withTimezone: true })
      .notNull()
      .default(sql`now()`)
  },
  table => [index('computer_agent_worker_bindings_worker_index').on(table.workerId)]
)
