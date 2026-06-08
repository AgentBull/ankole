import { and, eq, sql } from 'drizzle-orm'
import { DB, type AppDbTransaction, jsonbParam, type QueryExecutor } from '@/common/database'
import type { JsonValue } from '@/common/db-schema'
import { ComputerAgentWorkerBindings, ComputerAgentWorkerPins, ComputerWorkers } from '@/common/db-schema/computer'
import { AppEnv } from '@/config/env'
import { signComputerToken } from './tokens'

/** Health window: a worker is healthy if `ready` and seen within this interval. */
const HEALTH_INTERVAL = sql`now() - interval '30 seconds'`
const SESSION_TOKEN_TTL_SECONDS = 600

export type ComputerBindingKind = 'explicit_pin' | 'implicit' | 'fallback'

export class ComputerDomainError extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
    message: string
  ) {
    super(message)
    this.name = 'ComputerDomainError'
  }
}

export interface RegisterWorkerInput {
  workerId: string
  instanceId: string
  baseUrl: string
  version?: string | null
  features?: string[]
  capacity?: Record<string, JsonValue>
  metadata?: Record<string, JsonValue>
}

export interface HeartbeatInput {
  workerId: string
  instanceId: string
  status?: string
  runningSessions?: number
  runningCommands?: number
  load?: Record<string, JsonValue>
}

export interface ResolvedComputerWorker {
  workerId: string
  instanceId: string
  baseUrl: string
}

export interface ComputerResolveResult {
  agentUid: string
  worker: ResolvedComputerWorker
  binding: { kind: ComputerBindingKind; reason: string }
  token: string
}

export async function registerWorker(input: RegisterWorkerInput): Promise<void> {
  const shared = {
    instanceId: input.instanceId,
    baseUrl: input.baseUrl,
    status: 'ready',
    version: input.version ?? null,
    features: jsonbParam(input.features ?? []),
    capacity: jsonbParam(input.capacity ?? {}),
    metadata: jsonbParam(input.metadata ?? {})
  }
  await DB.insert(ComputerWorkers)
    .values({ workerId: input.workerId, ...shared })
    .onConflictDoUpdate({
      target: ComputerWorkers.workerId,
      set: { ...shared, lastHeartbeatAt: sql`now()`, updatedAt: sql`now()` }
    })
}

export async function recordHeartbeat(input: HeartbeatInput): Promise<void> {
  const load: Record<string, JsonValue> = {
    ...input.load,
    runningSessions: input.runningSessions ?? 0,
    runningCommands: input.runningCommands ?? 0
  }
  await DB.update(ComputerWorkers)
    .set({
      instanceId: input.instanceId,
      status: input.status ?? 'ready',
      load: jsonbParam(load),
      lastHeartbeatAt: sql`now()`,
      updatedAt: sql`now()`
    })
    .where(eq(ComputerWorkers.workerId, input.workerId))
}

/**
 * Resolve (or create) the sticky worker binding for an agent:
 *   1. healthy explicit pin → use it
 *   2. else existing healthy binding → reuse it
 *   3. else least-bound healthy worker (random tie-break) → new implicit/fallback binding
 *
 * The whole decision runs under a per-agent advisory lock so concurrent resolves
 * for the same agent converge on one worker.
 */
export async function resolveComputerWorker(agentUid: string): Promise<ComputerResolveResult> {
  const decision = await DB.transaction(async tx => {
    await tx.execute(sql`select pg_advisory_xact_lock(hashtext(${`computer-agent:${agentUid}`}))`)

    const pin = await getPin(tx, agentUid)
    if (pin && (await isHealthy(tx, pin.workerId))) {
      return upsertBinding(tx, agentUid, pin.workerId, 'explicit_pin', 'configured_pin')
    }

    const binding = await getBinding(tx, agentUid)
    if (binding && (await isHealthy(tx, binding.workerId))) {
      await touchBinding(tx, agentUid)
      const worker = await getWorker(tx, binding.workerId)
      return {
        worker,
        kind: binding.bindingKind as ComputerBindingKind,
        reason: binding.bindingReason ?? 'sticky_binding'
      }
    }

    const candidates = await getLeastBoundHealthyWorkers(tx)
    const selected = candidates[Math.floor(Math.random() * candidates.length)]
    if (!selected) {
      throw new ComputerDomainError(503, 'computer_no_worker_available', 'no healthy computer worker available')
    }
    const kind: ComputerBindingKind = pin ? 'fallback' : 'implicit'
    const reason = pin ? 'pin_worker_unavailable' : 'least_bound_random'
    return upsertBinding(tx, agentUid, selected, kind, reason)
  })

  return {
    agentUid,
    worker: decision.worker,
    binding: { kind: decision.kind, reason: decision.reason },
    token: mintSessionToken(agentUid, decision.worker)
  }
}

function mintSessionToken(agentUid: string, worker: ResolvedComputerWorker): string {
  const secret = AppEnv.BULLX_COMPUTER_TOKEN
  if (!secret) return '' // dev: worker auth disabled
  return signComputerToken(
    {
      agentUid,
      workerId: worker.workerId,
      instanceId: worker.instanceId,
      exp: Math.floor(Date.now() / 1000) + SESSION_TOKEN_TTL_SECONDS
    },
    secret
  )
}

async function getPin(tx: QueryExecutor, agentUid: string) {
  const [pin] = await tx
    .select({ workerId: ComputerAgentWorkerPins.workerId })
    .from(ComputerAgentWorkerPins)
    .where(eq(ComputerAgentWorkerPins.agentUid, agentUid))
    .limit(1)
  return pin
}

async function getBinding(tx: QueryExecutor, agentUid: string) {
  const [binding] = await tx
    .select({
      workerId: ComputerAgentWorkerBindings.workerId,
      bindingKind: ComputerAgentWorkerBindings.bindingKind,
      bindingReason: ComputerAgentWorkerBindings.bindingReason
    })
    .from(ComputerAgentWorkerBindings)
    .where(eq(ComputerAgentWorkerBindings.agentUid, agentUid))
    .limit(1)
  return binding
}

async function isHealthy(tx: QueryExecutor, workerId: string): Promise<boolean> {
  const [row] = await tx
    .select({ ok: sql<number>`1` })
    .from(ComputerWorkers)
    .where(
      and(
        eq(ComputerWorkers.workerId, workerId),
        eq(ComputerWorkers.status, 'ready'),
        sql`${ComputerWorkers.lastHeartbeatAt} > ${HEALTH_INTERVAL}`
      )
    )
    .limit(1)
  return row !== undefined
}

async function getWorker(tx: QueryExecutor, workerId: string): Promise<ResolvedComputerWorker> {
  const [worker] = await tx
    .select({
      workerId: ComputerWorkers.workerId,
      instanceId: ComputerWorkers.instanceId,
      baseUrl: ComputerWorkers.baseUrl
    })
    .from(ComputerWorkers)
    .where(eq(ComputerWorkers.workerId, workerId))
    .limit(1)
  if (!worker) throw new ComputerDomainError(503, 'computer_worker_gone', 'worker disappeared during resolve')
  return worker
}

/** Worker ids with the fewest bound agents among currently-healthy workers. */
async function getLeastBoundHealthyWorkers(tx: QueryExecutor): Promise<string[]> {
  const rows = (await tx.execute(sql`
    with healthy as (
      select worker_id
      from computer_workers
      where status = 'ready' and last_heartbeat_at > now() - interval '30 seconds'
    ),
    counts as (
      select hw.worker_id, count(b.agent_uid) as bound_agent_count
      from healthy hw
      left join computer_agent_worker_bindings b on b.worker_id = hw.worker_id
      group by hw.worker_id
    ),
    min_count as (select min(bound_agent_count) as value from counts)
    select c.worker_id
    from counts c, min_count m
    where c.bound_agent_count = m.value
  `)) as unknown as Array<{ worker_id: string }>
  return rows.map(row => row.worker_id)
}

async function touchBinding(tx: QueryExecutor, agentUid: string): Promise<void> {
  await tx
    .update(ComputerAgentWorkerBindings)
    .set({ lastResolvedAt: sql`now()`, updatedAt: sql`now()` })
    .where(eq(ComputerAgentWorkerBindings.agentUid, agentUid))
}

async function upsertBinding(
  tx: AppDbTransaction,
  agentUid: string,
  workerId: string,
  kind: ComputerBindingKind,
  reason: string
): Promise<{ worker: ResolvedComputerWorker; kind: ComputerBindingKind; reason: string }> {
  const worker = await getWorker(tx, workerId)
  const shared = { workerId, bindingKind: kind, bindingReason: reason, instanceId: worker.instanceId }
  await tx
    .insert(ComputerAgentWorkerBindings)
    .values({ agentUid, ...shared })
    .onConflictDoUpdate({
      target: ComputerAgentWorkerBindings.agentUid,
      set: { ...shared, updatedAt: sql`now()`, lastResolvedAt: sql`now()` }
    })
  return { worker, kind, reason }
}

// --- admin: pins + worker listing ---------------------------------------------

export interface SetPinInput {
  agentUid: string
  workerId: string
  reason?: string | null
  createdByPrincipalUid?: string | null
}

export async function setAgentPin(input: SetPinInput): Promise<void> {
  const [worker] = await DB.select({ workerId: ComputerWorkers.workerId })
    .from(ComputerWorkers)
    .where(eq(ComputerWorkers.workerId, input.workerId))
    .limit(1)
  if (!worker) throw new ComputerDomainError(404, 'computer_worker_not_found', `unknown worker: ${input.workerId}`)

  const shared = {
    workerId: input.workerId,
    reason: input.reason ?? null,
    createdByPrincipalUid: input.createdByPrincipalUid ?? null
  }
  await DB.insert(ComputerAgentWorkerPins)
    .values({ agentUid: input.agentUid, ...shared })
    .onConflictDoUpdate({ target: ComputerAgentWorkerPins.agentUid, set: { ...shared, updatedAt: sql`now()` } })
}

export async function removeAgentPin(agentUid: string): Promise<void> {
  await DB.delete(ComputerAgentWorkerPins).where(eq(ComputerAgentWorkerPins.agentUid, agentUid))
}

export async function listWorkers() {
  return DB.select().from(ComputerWorkers).orderBy(ComputerWorkers.workerId)
}
