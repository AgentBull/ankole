import { sql } from 'drizzle-orm'
import { index, jsonb, pgTable, text, timestamp } from 'drizzle-orm/pg-core'

type JsonObject = Record<string, unknown>

/**
 * Registered agent computer workers (`bullx-computerd` instances). One row per
 * stable worker id.
 *
 * A row is the control plane's view of a worker process: it is created on
 * registration, refreshed by heartbeats, and stays as the source of truth for
 * where an agent's computer work can run. `worker_id` is stable across restarts;
 * `instance_id` changes per process lifetime, so a mismatch signals the worker
 * was restarted underneath us.
 */
export const ComputerWorkers = pgTable('computer_workers', {
  workerId: text('worker_id').primaryKey().notNull(),
  // Distinguishes a fresh process from a reconnect of the same logical worker.
  instanceId: text('instance_id').notNull(),
  baseUrl: text('base_url').notNull(),
  // Self-reported lifecycle state; starts at 'starting' on registration. Not
  // constrained at the DB level, and a 'ready'-looking row is still considered
  // dead once last_heartbeat_at has lapsed — liveness is the heartbeat, not this
  // field alone.
  status: text('status').notNull().default('starting'),
  version: text('version'),
  // Capability flags the resolver matches against an agent's requirements.
  features: jsonb('features').$type<string[]>().notNull().default([]),
  // Declared limits (capacity) vs current utilization (load); both are free-form
  // JSON the resolver reads to pick a worker, not a fixed schema.
  capacity: jsonb('capacity').$type<JsonObject>().notNull().default({}),
  load: jsonb('load').$type<JsonObject>().notNull().default({}),
  metadata: jsonb('metadata').$type<JsonObject>().notNull().default({}),
  registeredAt: timestamp('registered_at', { withTimezone: true })
    .notNull()
    .default(sql`now()`),
  // Liveness signal; a worker whose heartbeat has lapsed is treated as gone even
  // if its row still says 'ready'.
  lastHeartbeatAt: timestamp('last_heartbeat_at', { withTimezone: true })
    .notNull()
    .default(sql`now()`),
  updatedAt: timestamp('updated_at', { withTimezone: true })
    .notNull()
    .default(sql`now()`)
})

/**
 * Explicit agent→worker pins, configured from the admin console.
 *
 * Operator *intent*: "this agent should run on that worker." One pin per agent
 * (agent_uid is the PK). The resolver reads pins as the highest-priority input
 * but the actual chosen binding lives in {@link ComputerAgentWorkerBindings} —
 * the two are kept separate so a pin can outlive a momentarily-unavailable worker
 * without corrupting the live binding.
 */
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
  // Reverse lookup: list every agent pinned to a given worker (the PK only
  // indexes the agent→worker direction).
  table => [index('computer_agent_worker_pins_worker_index').on(table.workerId)]
)

/**
 * Actual sticky agent→worker bindings produced by the resolver.
 *
 * The resolved *outcome* the rest of the system routes against, one per agent.
 * Stickiness is the point: once an agent is bound to a worker it stays there
 * (recorded in last_resolved_at) instead of being re-picked each request, so an
 * agent's computer session keeps landing on the same machine.
 */
export const ComputerAgentWorkerBindings = pgTable(
  'computer_agent_worker_bindings',
  {
    agentUid: text('agent_uid').primaryKey().notNull(),
    workerId: text('worker_id')
      .notNull()
      .references(() => ComputerWorkers.workerId),
    // How this binding was reached: explicit_pin (from a pin row) | implicit
    // (resolver's sticky/best choice) | fallback (no better option available).
    bindingKind: text('binding_kind').notNull(),
    bindingReason: text('binding_reason'),
    // Worker instance this binding last resolved against; lets a worker restart
    // (new instance_id) be detected and the binding re-checked.
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
  // Reverse lookup: find all agents currently bound to a worker, e.g. to rebind
  // them when that worker goes down.
  table => [index('computer_agent_worker_bindings_worker_index').on(table.workerId)]
)
