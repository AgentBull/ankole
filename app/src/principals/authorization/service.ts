import { authzAuthorize, authzAuthorizeAll } from '@agentbull/bullx-native-addons'
import { and, eq, inArray, or } from 'drizzle-orm'
import { DB, type QueryExecutor } from '@/common/database'
import { PermissionGrants, PrincipalGroupMemberships, PrincipalGroups, Principals } from '@/common/db-schema'
import { logger } from '@/common/logger'
import { normalizeUid, type Principal, PrincipalDomainError } from '../principals/service'
import {
  ADMIN_GROUP_NAME,
  ALL_HUMANS_CONDITION,
  ALL_HUMANS_GROUP_NAME,
  ensureBuiltInAdminGroup,
  ensureBuiltInAllHumansGroup
} from './groups'
import { adminMemberExists, insertMembership } from './memberships'
import { buildAuthorizationRequest, splitPermissionKey } from './request'

export { createPermissionGrant, deletePermissionGrant, updatePermissionGrant, upsertPermissionGrant } from './grants'
export {
  createPrincipalGroup,
  deletePrincipalGroup,
  ensureBuiltInAdminGroup,
  ensureBuiltInAllHumansGroup,
  listPrincipalGroups,
  updatePrincipalGroup
} from './groups'
export { addPrincipalToGroup, ensureCanDisablePrincipal, removePrincipalFromGroup } from './memberships'

/**
 * Native decision shape after NAPI serde conversion.
 */
interface NativeAuthzDecision {
  status: 'allow' | 'deny' | 'principal_disabled' | 'invalid_request'
  diagnostics: NativeAuthzDiagnostic[]
  effectiveGroupIds: string[]
  deniedAction?: string
}

interface NativeAuthzDiagnostic {
  kind: string
  id: string
  action?: string | null
  resourcePattern?: string | null
  reason: string
}

/**
 * Authorizes one exact action on one concrete resource.
 *
 * The TS layer loads database state into a plain JSON snapshot. The native
 * engine performs the actual decision so CEL evaluation and resource-pattern
 * semantics stay centralized.
 */
export async function authorize(
  principalOrUid: Principal | string,
  resource: string,
  action: string,
  context: Record<string, unknown> = {}
): Promise<void> {
  const request = buildAuthorizationRequest(principalOrUid, resource, action, context)
  const snapshot = await loadAuthorizationSnapshot(
    request.principalUid,
    request.resource,
    [request.action],
    request.context
  )
  const decision = authzAuthorize({ ...snapshot, action: request.action }) as NativeAuthzDecision

  handleDiagnostics(decision.diagnostics)
  handleDecision(decision)
}

/**
 * Authorizes a batch of exact actions against the same concrete resource.
 *
 * The snapshot is loaded once and native returns the first denied action, which
 * keeps multi-permission checks consistent with single-action authorization.
 */
export async function authorizeAll(
  principalOrUid: Principal | string,
  resource: string,
  actions: string[],
  context: Record<string, unknown> = {}
): Promise<void> {
  if (actions.length === 0) throw new PrincipalDomainError('invalid_request', 'actions must not be empty')

  const requests = actions.map(action => buildAuthorizationRequest(principalOrUid, resource, action, context))
  const principalUid = requests[0]?.principalUid
  const normalizedResource = requests[0]?.resource
  const normalizedContext = requests[0]?.context ?? {}

  if (!principalUid || !normalizedResource) throw new PrincipalDomainError('invalid_request')

  const normalizedActions = requests.map(request => request.action)
  const snapshot = await loadAuthorizationSnapshot(
    principalUid,
    normalizedResource,
    normalizedActions,
    normalizedContext
  )
  const decision = authzAuthorizeAll({
    ...snapshot,
    actions: normalizedActions
  }) as NativeAuthzDecision

  handleDiagnostics(decision.diagnostics)
  handleDecision(decision)
}

/**
 * Authorizes a compact `resource:action` permission key.
 */
export async function authorizePermission(
  principalOrUid: Principal | string,
  permission: string,
  context: Record<string, unknown> = {}
): Promise<void> {
  const { resource, action } = splitPermissionKey(permission)
  await authorize(principalOrUid, resource, action, context)
}

/**
 * Boolean form of `authorize`.
 *
 * This intentionally collapses all domain errors to `false`; callers that need
 * diagnostics or failure reasons should use `authorize`.
 */
export async function allowed(
  principalOrUid: Principal | string,
  resource: string,
  action: string,
  context: Record<string, unknown> = {}
): Promise<boolean> {
  try {
    await authorize(principalOrUid, resource, action, context)
    return true
  } catch {
    return false
  }
}

/**
 * Returns true after both built-in AuthZ groups exist.
 *
 * Table-absence errors are treated as false so bootstrap probes can run before
 * migrations have created the Principal/AuthZ tables.
 */
export async function rootInitialized(): Promise<boolean> {
  try {
    const [admin] = await DB.select({ id: PrincipalGroups.id })
      .from(PrincipalGroups)
      .where(and(eq(PrincipalGroups.name, ADMIN_GROUP_NAME), eq(PrincipalGroups.builtIn, true)))
      .limit(1)

    const [allHumans] = await DB.select({ id: PrincipalGroups.id })
      .from(PrincipalGroups)
      .where(
        and(
          eq(PrincipalGroups.name, ALL_HUMANS_GROUP_NAME),
          eq(PrincipalGroups.kind, 'computed'),
          eq(PrincipalGroups.computedCondition, ALL_HUMANS_CONDITION),
          eq(PrincipalGroups.builtIn, true)
        )
      )
      .limit(1)

    return admin !== undefined && allHumans !== undefined
  } catch (error) {
    logger.debug({ error }, 'AuthZ rootInitialized table check failed')
    return false
  }
}

/**
 * Ensures root initialization is still claimable.
 *
 * The installation is considered closed as soon as the built-in admin group has
 * any membership.
 */
export async function ensureRootInitOpen(db: QueryExecutor = DB): Promise<void> {
  if (await adminMemberExists(db)) throw new PrincipalDomainError('root_init_closed')
}

/**
 * Claims the first root admin membership for an active human Principal.
 *
 * The transaction locks the Principal and admin group, then rechecks open state
 * before inserting membership. This prevents two concurrent root-init attempts
 * from both observing an empty admin group and racing to claim it.
 */
export async function rootInitAdmin(principalUid: string): Promise<void> {
  const uid = normalizeUid(principalUid)

  await DB.transaction(async tx => {
    const [principal] = await tx.select().from(Principals).where(eq(Principals.uid, uid)).for('update').limit(1)
    if (!principal) throw new PrincipalDomainError('not_found')

    if (principal.type !== 'human') throw new PrincipalDomainError('not_human')

    if (principal.status !== 'active') throw new PrincipalDomainError('principal_disabled')

    await ensureBuiltInAllHumansGroup(tx)
    const admin = await ensureBuiltInAdminGroup(tx)

    const [lockedAdmin] = await tx
      .select()
      .from(PrincipalGroups)
      .where(eq(PrincipalGroups.id, admin.id))
      .for('update')
      .limit(1)
    if (!lockedAdmin) throw new PrincipalDomainError('not_found')

    await ensureRootInitOpen(tx)
    await insertMembership(principal.uid, lockedAdmin.id, tx)
  })
}

/**
 * Loads the authorization snapshot passed to native.
 *
 * Candidate grants include direct grants, grants for static groups the
 * Principal already belongs to, and grants for every computed group. Native then
 * evaluates computed membership and ignores grants whose owner is not effective.
 */
async function loadAuthorizationSnapshot(
  principalUid: string,
  resource: string,
  actions: string[],
  context: Record<string, unknown>
) {
  const [principal] = await DB.select().from(Principals).where(eq(Principals.uid, principalUid)).limit(1)
  if (!principal) throw new PrincipalDomainError('not_found')

  const staticMemberships = await DB.select({ groupId: PrincipalGroupMemberships.groupId })
    .from(PrincipalGroupMemberships)
    .innerJoin(PrincipalGroups, eq(PrincipalGroups.id, PrincipalGroupMemberships.groupId))
    .where(and(eq(PrincipalGroupMemberships.principalUid, principal.uid), eq(PrincipalGroups.kind, 'static')))

  const computedGroups = await DB.select({
    id: PrincipalGroups.id,
    condition: PrincipalGroups.computedCondition
  })
    .from(PrincipalGroups)
    .where(eq(PrincipalGroups.kind, 'computed'))

  const staticGroupIds = staticMemberships.map(membership => membership.groupId)
  const computedGroupIds = computedGroups.map(group => group.id)
  const candidateGroupIds = [...staticGroupIds, ...computedGroupIds]

  // Filtering by action in SQL keeps the snapshot small while still allowing
  // native to own the resource-pattern and CEL semantics.
  const ownerFilter =
    candidateGroupIds.length > 0
      ? or(eq(PermissionGrants.principalUid, principal.uid), inArray(PermissionGrants.groupId, candidateGroupIds))
      : eq(PermissionGrants.principalUid, principal.uid)

  const grants = await DB.select()
    .from(PermissionGrants)
    .where(and(inArray(PermissionGrants.action, actions), ownerFilter))

  return {
    principal: {
      uid: principal.uid,
      type: principal.type,
      status: principal.status,
      displayName: principal.displayName,
      avatarUrl: principal.avatarUrl
    },
    staticGroupIds,
    computedGroups: computedGroups.map(group => ({
      id: group.id,
      condition: group.condition ?? 'false'
    })),
    grants: grants.map(grant => ({
      id: grant.id,
      principalUid: grant.principalUid,
      groupId: grant.groupId,
      resourcePattern: grant.resourcePattern,
      action: grant.action,
      condition: grant.condition
    })),
    resource,
    context: jsonSnapshot(context)
  }
}

/**
 * Converts native status strings into Principal/AuthZ domain errors.
 */
function handleDecision(decision: NativeAuthzDecision): void {
  switch (decision.status) {
    case 'allow':
      return
    case 'principal_disabled':
      throw new PrincipalDomainError('principal_disabled')
    case 'invalid_request':
      throw new PrincipalDomainError('invalid_request')
    case 'deny':
      throw new PrincipalDomainError(
        'forbidden',
        decision.deniedAction ? `forbidden: ${decision.deniedAction}` : 'forbidden'
      )
  }
}

/**
 * Invalid persisted CEL or resource patterns are security-relevant operator
 * errors. Native fails closed; TS records diagnostics for operational follow-up.
 */
function handleDiagnostics(diagnostics: NativeAuthzDiagnostic[]): void {
  for (const diagnostic of diagnostics) logger.error({ diagnostic }, 'AuthZ invalid persisted data')
}

/**
 * Removes prototypes and non-JSON values before crossing the NAPI boundary.
 */
function jsonSnapshot(value: Record<string, unknown>): Record<string, unknown> {
  return JSON.parse(JSON.stringify(value))
}
