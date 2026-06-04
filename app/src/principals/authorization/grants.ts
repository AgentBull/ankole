import { authzValidateCondition, authzValidateResourcePattern } from '@agentbull/bullx-native-addons'
import { eq, sql } from 'drizzle-orm'
import { DB, jsonbParam, type QueryExecutor } from '@/common/database'
import { type JsonObject, PermissionGrants } from '@/common/db-schema'
import { newPrincipalDomainRowId, normalizeUid, PrincipalDomainError, trimOptionalText } from '../principals/service'
import { normalizeAction } from './request'

export type PermissionGrant = typeof PermissionGrants.$inferSelect

export interface PermissionGrantInput {
  principalUid?: string | null
  groupId?: string | null
  resourcePattern: string
  action: string
  condition?: string | null
  description?: string | null
  metadata?: JsonObject
}

/**
 * Creates a permission grant for exactly one Principal or one group.
 *
 * The native engine still validates persisted resource patterns and CEL
 * conditions at authorization time, but write-time validation catches operator
 * mistakes before they become fail-closed grants.
 */
export async function createPermissionGrant(
  input: PermissionGrantInput,
  db: QueryExecutor = DB
): Promise<PermissionGrant> {
  const attrs = normalizePermissionGrantInput(input)

  const [grant] = await db
    .insert(PermissionGrants)
    .values({
      id: newPrincipalDomainRowId(),
      ...attrs,
      metadata: jsonbParam(attrs.metadata ?? {})
    })
    .returning()

  return grant
}

/**
 * Inserts or replaces a grant identified by owner, resource pattern, action,
 * and condition.
 */
export async function upsertPermissionGrant(
  input: PermissionGrantInput,
  db: QueryExecutor = DB
): Promise<PermissionGrant> {
  const attrs = normalizePermissionGrantInput(input)
  const values = {
    id: newPrincipalDomainRowId(),
    ...attrs,
    metadata: jsonbParam(attrs.metadata ?? {})
  }

  if (attrs.principalUid) {
    const [grant] = await db
      .insert(PermissionGrants)
      .values(values)
      .onConflictDoUpdate({
        target: [
          PermissionGrants.principalUid,
          PermissionGrants.resourcePattern,
          PermissionGrants.action,
          PermissionGrants.condition
        ],
        targetWhere: sql`${PermissionGrants.principalUid} IS NOT NULL`,
        set: {
          description: attrs.description,
          metadata: jsonbParam(attrs.metadata ?? {}),
          updatedAt: sql`CURRENT_TIMESTAMP`
        }
      })
      .returning()

    return grant
  }

  const [grant] = await db
    .insert(PermissionGrants)
    .values(values)
    .onConflictDoUpdate({
      target: [
        PermissionGrants.groupId,
        PermissionGrants.resourcePattern,
        PermissionGrants.action,
        PermissionGrants.condition
      ],
      targetWhere: sql`${PermissionGrants.groupId} IS NOT NULL`,
      set: {
        description: attrs.description,
        metadata: jsonbParam(attrs.metadata ?? {}),
        updatedAt: sql`CURRENT_TIMESTAMP`
      }
    })
    .returning()

  return grant
}

/**
 * Updates a grant by normalizing the merged old/new shape.
 *
 * Re-running full validation here is important because changing only the owner
 * can still violate the "one principal or one group" ownership invariant.
 */
export async function updatePermissionGrant(
  id: string,
  input: Partial<PermissionGrantInput>,
  db: QueryExecutor = DB
): Promise<PermissionGrant> {
  const [existing] = await db.select().from(PermissionGrants).where(eq(PermissionGrants.id, id)).limit(1)
  if (!existing) throw new PrincipalDomainError('not_found')

  const merged = normalizePermissionGrantInput({
    principalUid: input.principalUid === undefined ? existing.principalUid : input.principalUid,
    groupId: input.groupId === undefined ? existing.groupId : input.groupId,
    resourcePattern: input.resourcePattern ?? existing.resourcePattern,
    action: input.action ?? existing.action,
    condition: input.condition === undefined ? existing.condition : input.condition,
    description: input.description === undefined ? existing.description : input.description,
    metadata: input.metadata ?? existing.metadata
  })

  const [updated] = await db
    .update(PermissionGrants)
    .set({
      ...merged,
      metadata: jsonbParam(merged.metadata ?? {}),
      updatedAt: sql`CURRENT_TIMESTAMP`
    })
    .where(eq(PermissionGrants.id, id))
    .returning()

  return updated
}

/**
 * Deletes a permission grant by id.
 */
export async function deletePermissionGrant(id: string, db: QueryExecutor = DB): Promise<void> {
  const deleted = await db
    .delete(PermissionGrants)
    .where(eq(PermissionGrants.id, id))
    .returning({ id: PermissionGrants.id })
  if (deleted.length === 0) throw new PrincipalDomainError('not_found')
}

function normalizePermissionGrantInput(input: PermissionGrantInput): Omit<typeof PermissionGrants.$inferInsert, 'id'> {
  const principalUid = input.principalUid ? normalizeUid(input.principalUid) : null
  const groupId = trimOptionalText(input.groupId)

  if ((principalUid && groupId) || (!principalUid && !groupId)) {
    throw new PrincipalDomainError('invalid_request', 'permission grant requires exactly one owner')
  }

  const resourcePattern = normalizeResourcePattern(input.resourcePattern)
  const action = normalizeAction(input.action)
  const condition = normalizeCondition(input.condition)
  const metadata = input.metadata ?? {}

  if (!isJsonObject(metadata)) throw new PrincipalDomainError('invalid_request', 'metadata must be a JSON object')

  return {
    principalUid,
    groupId,
    resourcePattern,
    action,
    condition,
    description: trimOptionalText(input.description),
    metadata
  }
}

function normalizeResourcePattern(pattern: string): string {
  const normalized = pattern.trim()
  if (!normalized) throw new PrincipalDomainError('invalid_request', 'resourcePattern must not be empty')

  authzValidateResourcePattern(normalized)
  return normalized
}

/**
 * Empty grant conditions mean unconditional allow for a matching grant.
 */
function normalizeCondition(condition: string | null | undefined): string {
  const normalized = trimOptionalText(condition) ?? 'true'
  authzValidateCondition(normalized)
  return normalized
}

function isJsonObject(value: unknown): value is JsonObject {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}
