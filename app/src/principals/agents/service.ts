import { eq, sql } from 'drizzle-orm'
import type { PgUpdateSetSource } from 'drizzle-orm/pg-core'
import { DB, jsonbParam } from '@/common/database'
import { Agents, type JsonObject, Principals } from '@/common/db-schema'
import { isJsonObject } from '@/common/json'
import { seedDefaultMissionForAgent, seedDefaultSoulForAgent } from '@/ai-agent/library/service'
import {
  normalizeUid,
  type Principal,
  PrincipalDomainError,
  trimOptionalText,
  updatePrincipalStatus
} from '../principals/service'

// Agent lifecycle within the Principal model.
//
// An agent is a first-class Principal (`principals.type = 'agent'`), the same
// kind of authorization subject as a human: it owns a UID, can hold grants and
// group memberships, and shares the lifecycle status field. What distinguishes
// an agent is the subtype row in `agents` — its runtime `type` (only
// `llm_agentic_loop` in V1), free-form `metadata`, and a `createdByPrincipalUid`
// provenance link — plus that an agent never logs into the admin console (see
// `activeHumanAdmin`, which is human-only). Because identity and profile live in
// two tables, every create/update keeps the Principal row and the agent row in
// one transaction, and reads return them as separate fields rather than a merged
// object so callers do not have to track which column came from which table.

export type Agent = typeof Agents.$inferSelect
export type AgentType = Agent['type']

export interface CreateAgentInput {
  uid: string
  displayName?: string | null
  avatarUrl?: string | null
  type?: AgentType
  metadata?: JsonObject
  createdByPrincipalUid?: string | null
}

export interface UpdateAgentInput {
  displayName?: string | null
  avatarUrl?: string | null
  type?: AgentType
  metadata?: JsonObject
}

export interface AgentResult {
  principal: Principal
  agent: Agent
}

/**
 * Loads an agent and its backing Principal by UID.
 *
 * A truly absent UID returns `undefined` (callers use this as an existence
 * check). A UID that exists but resolves to a non-agent Principal is a different,
 * worse situation — caller asked for an agent and got something else — so it
 * throws rather than masquerading as "not found".
 */
export async function getAgent(uid: string): Promise<AgentResult | undefined> {
  const principalUid = normalizeUid(uid)
  const [row] = await DB.select({ principal: Principals, agent: Agents })
    .from(Agents)
    .innerJoin(Principals, eq(Principals.uid, Agents.uid))
    .where(eq(Agents.uid, principalUid))
    .limit(1)

  if (!row) return undefined
  if (row.principal.type !== 'agent') throw new PrincipalDomainError('not_agent')

  return {
    principal: row.principal,
    agent: row.agent
  }
}

/**
 * Creates an agent Principal and its agent subtype row atomically.
 *
 * The UID becomes the stable subject identity for future grants and external
 * bindings. `metadata` is constrained to a JSON object so additional agent
 * runtime attributes can be added without changing the method signature.
 */
export async function createAgent(input: CreateAgentInput): Promise<AgentResult> {
  const uid = normalizeUid(input.uid)
  const metadata = normalizeMetadata(input.metadata)

  return DB.transaction(async tx => {
    const [principal] = await tx
      .insert(Principals)
      .values({
        uid,
        type: 'agent',
        status: 'active',
        displayName: trimOptionalText(input.displayName),
        avatarUrl: trimOptionalText(input.avatarUrl)
      })
      .returning()

    const [agent] = await tx
      .insert(Agents)
      .values({
        uid: principal.uid,
        type: input.type ?? 'llm_agentic_loop',
        metadata: jsonbParam(metadata),
        createdByPrincipalUid: input.createdByPrincipalUid ? normalizeUid(input.createdByPrincipalUid) : null
      })
      .returning()

    // A new agent is seeded with a default soul and mission in the same
    // transaction so it is never observable in a half-provisioned state: either
    // the principal, agent row, soul, and mission all exist, or none do.
    await seedDefaultSoulForAgent(agent.uid, tx)
    await seedDefaultMissionForAgent(agent.uid, tx)

    return { principal, agent }
  })
}

/**
 * Updates agent-owned mutable attributes.
 *
 * This intentionally does not allow changing the Principal UID or Principal
 * type. Those fields are subject identity, not agent profile data.
 */
export async function updateAgent(uid: string, input: UpdateAgentInput): Promise<AgentResult> {
  const principalUid = normalizeUid(uid)

  return DB.transaction(async tx => {
    const [principal] = await tx
      .select()
      .from(Principals)
      .where(eq(Principals.uid, principalUid))
      .for('update')
      .limit(1)

    if (!principal) throw new PrincipalDomainError('not_found')

    if (principal.type !== 'agent') throw new PrincipalDomainError('not_agent')

    const principalPatch: PgUpdateSetSource<typeof Principals> = {
      updatedAt: sql`CURRENT_TIMESTAMP`
    }

    // Profile fields use key presence (`'x' in input`), not value, so passing
    // `null` explicitly clears the field while omitting the key leaves it
    // untouched — the standard PATCH-vs-PUT distinction for nullable columns.
    if ('displayName' in input) principalPatch.displayName = trimOptionalText(input.displayName)

    if ('avatarUrl' in input) principalPatch.avatarUrl = trimOptionalText(input.avatarUrl)

    const [updatedPrincipal] = await tx
      .update(Principals)
      .set(principalPatch)
      .where(eq(Principals.uid, principal.uid))
      .returning()

    const agentPatch: PgUpdateSetSource<typeof Agents> = {
      updatedAt: sql`CURRENT_TIMESTAMP`
    }

    if (input.type !== undefined) agentPatch.type = input.type

    if (input.metadata !== undefined) agentPatch.metadata = jsonbParam(normalizeMetadata(input.metadata))

    const [agent] = await tx.update(Agents).set(agentPatch).where(eq(Agents.uid, principal.uid)).returning()
    if (!agent) throw new PrincipalDomainError('not_agent')

    return { principal: updatedPrincipal, agent }
  })
}

/**
 * Soft-disables an agent by flipping its Principal status to `disabled`.
 *
 * Disabling is a status change, not a delete: the row and its UID stay so grants,
 * history, and provenance links remain intact and the agent can be reasoned
 * about (or re-enabled) later. No lockout guard is needed here — unlike humans,
 * agents are not part of the admin-recovery path.
 */
export async function disableAgent(uid: string): Promise<AgentResult> {
  const existing = await getAgent(uid)
  if (!existing) throw new PrincipalDomainError('not_found')

  const principal = await updatePrincipalStatus(existing.principal.uid, 'disabled')
  return {
    principal,
    agent: existing.agent
  }
}

/**
 * Lists active agent Principals ordered by agent creation time.
 *
 * The return shape keeps the top-level Principal and subtype row separate so
 * callers do not have to remember which fields live in which table.
 */
export async function listActiveAgents(): Promise<AgentResult[]> {
  const rows = await DB.select({ principal: Principals, agent: Agents })
    .from(Agents)
    .innerJoin(Principals, eq(Principals.uid, Agents.uid))
    .where(sql`${Principals.status} = 'active' AND ${Principals.type} = 'agent'`)
    .orderBy(Agents.createdAt)

  return rows.map(row => ({
    principal: row.principal,
    agent: row.agent
  }))
}

/**
 * Coerces missing metadata to an empty object and rejects non-object shapes.
 *
 * The `agents.metadata` column is constrained to a JSON object at the database
 * level; validating here turns a would-be constraint violation into a clean
 * domain error and guarantees the stored value is always an object, never an
 * array or scalar.
 */
function normalizeMetadata(value: JsonObject | undefined): JsonObject {
  if (value === undefined) return {}

  if (!isJsonObject(value)) throw new PrincipalDomainError('invalid_request', 'metadata must be a JSON object')

  return value
}
