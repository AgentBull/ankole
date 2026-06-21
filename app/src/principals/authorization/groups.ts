import { authzValidateCondition } from '@agentbull/bullx-native-addons'
import { eq, sql } from 'drizzle-orm'
import { DB, type QueryExecutor } from '@/common/database'
import { PermissionGrants, PrincipalGroups } from '@/common/db-schema'
import { newPrincipalDomainRowId, PrincipalDomainError, trimOptionalText } from '../principals/service'

export const ADMIN_GROUP_NAME = 'admin'
export const ALL_HUMANS_GROUP_NAME = 'all_humans'

/**
 * Built-in computed membership for active human Principals.
 *
 * The native engine evaluates this condition from the plain Principal snapshot;
 * there is no stored membership row for `all_humans`.
 */
export const ALL_HUMANS_CONDITION = 'principal.type == "human" && principal.status == "active"'

export type PrincipalGroup = typeof PrincipalGroups.$inferSelect
export type PrincipalGroupKind = PrincipalGroup['kind']

export interface CreatePrincipalGroupInput {
  name: string
  kind?: PrincipalGroupKind
  description?: string | null
  computedCondition?: string | null
}

export interface UpdatePrincipalGroupInput {
  description?: string | null
  computedCondition?: string | null
}

/**
 * Lists all Principal groups ordered by name.
 */
export async function listPrincipalGroups(db: QueryExecutor = DB): Promise<PrincipalGroup[]> {
  return db.select().from(PrincipalGroups).orderBy(PrincipalGroups.name)
}

/**
 * Creates a static or computed group.
 *
 * Computed groups must have a CEL condition that compiles in the native engine;
 * static groups must not have one because their membership comes from
 * `principal_group_memberships`.
 */
export async function createPrincipalGroup(
  input: CreatePrincipalGroupInput,
  db: QueryExecutor = DB
): Promise<PrincipalGroup> {
  const attrs = normalizeGroupInput(input)

  const [group] = await db
    .insert(PrincipalGroups)
    .values({
      id: newPrincipalDomainRowId(),
      ...attrs
    })
    .returning()

  return group
}

/**
 * Updates mutable group attributes.
 *
 * The group kind is intentionally stable after creation because changing static
 * to computed would reinterpret existing membership rows.
 */
export async function updatePrincipalGroup(
  id: string,
  input: UpdatePrincipalGroupInput,
  db: QueryExecutor = DB
): Promise<PrincipalGroup> {
  const [existing] = await db.select().from(PrincipalGroups).where(eq(PrincipalGroups.id, id)).limit(1)
  if (!existing) throw new PrincipalDomainError('not_found')

  const patch: Partial<typeof PrincipalGroups.$inferInsert> = {
    updatedAt: sql`CURRENT_TIMESTAMP` as never
  }

  if ('description' in input) patch.description = trimOptionalText(input.description)

  if ('computedCondition' in input) {
    patch.computedCondition = normalizeComputedCondition(existing.kind, input.computedCondition)
  }

  const [updated] = await db.update(PrincipalGroups).set(patch).where(eq(PrincipalGroups.id, id)).returning()
  return updated
}

/**
 * Deletes an operator-created group when it is not still referenced by grants.
 */
export async function deletePrincipalGroup(id: string, db: QueryExecutor = DB): Promise<void> {
  const [group] = await db.select().from(PrincipalGroups).where(eq(PrincipalGroups.id, id)).limit(1)
  if (!group) throw new PrincipalDomainError('not_found')

  if (group.builtIn) throw new PrincipalDomainError('built_in_group')

  const [grant] = await db
    .select({ id: PermissionGrants.id })
    .from(PermissionGrants)
    .where(eq(PermissionGrants.groupId, group.id))
    .limit(1)
  if (grant) throw new PrincipalDomainError('group_has_grants')

  await db.delete(PrincipalGroups).where(eq(PrincipalGroups.id, group.id))
}

/**
 * Ensures the built-in static admin group exists.
 *
 * A same-name non-built-in row is treated as a conflict so root/admin safety
 * cannot be attached to an operator-created group by accident.
 */
export async function ensureBuiltInAdminGroup(db: QueryExecutor = DB): Promise<PrincipalGroup> {
  return ensureBuiltInGroup(
    {
      name: ADMIN_GROUP_NAME,
      kind: 'static',
      description: 'Built-in administrators group.',
      computedCondition: null
    },
    db
  )
}

/**
 * Ensures the built-in computed `all_humans` group exists.
 */
export async function ensureBuiltInAllHumansGroup(db: QueryExecutor = DB): Promise<PrincipalGroup> {
  return ensureBuiltInGroup(
    {
      name: ALL_HUMANS_GROUP_NAME,
      kind: 'computed',
      description: 'Built-in computed group for all active Human Principals.',
      computedCondition: ALL_HUMANS_CONDITION
    },
    db
  )
}

/**
 * Idempotently ensures a built-in group exists with the exact expected shape.
 *
 * Safe to call on every boot. If a row with the name already exists it must
 * match on `builtIn`, `kind`, and (for computed groups) the exact condition;
 * any mismatch throws `conflicting_built_in_group` instead of silently adopting
 * or mutating the row. That refusal is the safety property: admin/root checks
 * key off these built-in rows, so a same-name operator group, or a drifted
 * condition, must never be mistaken for the real built-in.
 */
async function ensureBuiltInGroup(
  input: Required<CreatePrincipalGroupInput>,
  db: QueryExecutor
): Promise<PrincipalGroup> {
  const attrs = normalizeGroupInput(input)
  const [existing] = await db.select().from(PrincipalGroups).where(eq(PrincipalGroups.name, attrs.name)).limit(1)

  if (existing) {
    if (!existing.builtIn || existing.kind !== attrs.kind) throw new PrincipalDomainError('conflicting_built_in_group')

    if (attrs.kind === 'computed' && existing.computedCondition !== attrs.computedCondition) {
      throw new PrincipalDomainError('conflicting_built_in_group')
    }

    if (attrs.kind === 'static' && existing.computedCondition !== null) {
      throw new PrincipalDomainError('conflicting_built_in_group')
    }

    return existing
  }

  const [created] = await db
    .insert(PrincipalGroups)
    .values({
      id: newPrincipalDomainRowId(),
      ...attrs,
      builtIn: true
    })
    .returning()

  return created
}

function normalizeGroupInput(
  input: CreatePrincipalGroupInput
): Omit<typeof PrincipalGroups.$inferInsert, 'id' | 'builtIn'> {
  const name = normalizeGroupName(input.name)
  const kind = input.kind ?? 'static'
  const computedCondition = normalizeComputedCondition(kind, input.computedCondition)

  return {
    name,
    kind,
    description: trimOptionalText(input.description),
    computedCondition
  }
}

function normalizeGroupName(name: string): string {
  const normalized = name.trim().toLowerCase()
  if (!normalized) throw new PrincipalDomainError('invalid_request', 'group name must not be empty')

  return normalized
}

function normalizeComputedCondition(kind: PrincipalGroupKind, condition: string | null | undefined): string | null {
  const normalized = trimOptionalText(condition)

  if (kind === 'static') {
    if (normalized !== null) {
      throw new PrincipalDomainError('invalid_request', 'static group must not have computedCondition')
    }

    return null
  }

  if (normalized === null) {
    throw new PrincipalDomainError('invalid_request', 'computed group requires computedCondition')
  }

  authzValidateCondition(normalized)
  return normalized
}
