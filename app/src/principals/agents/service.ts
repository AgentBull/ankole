import { eq, sql } from 'drizzle-orm'
import type { PgUpdateSetSource } from 'drizzle-orm/pg-core'
import { DB, jsonbParam } from '@/common/database'
import { Agents, type JsonObject, Principals } from '@/common/db-schema'
import {
  newPrincipalId,
  normalizeUid,
  type Principal,
  PrincipalDomainError,
  trimOptionalText
} from '../principals/service'

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
        id: newPrincipalId(),
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

function normalizeMetadata(value: JsonObject | undefined): JsonObject {
  if (value === undefined) return {}

  if (!isJsonObject(value)) throw new PrincipalDomainError('invalid_request', 'metadata must be a JSON object')

  return value
}

function isJsonObject(value: unknown): value is JsonObject {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}
