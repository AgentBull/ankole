import { and, eq, ne } from 'drizzle-orm'
import { DB, type QueryExecutor } from '@/common/database'
import { PrincipalGroupMemberships, PrincipalGroups, Principals } from '@/common/db-schema'
import { normalizeUid, type Principal, PrincipalDomainError } from '../principals/service'
import { ADMIN_GROUP_NAME } from './groups'

export type PrincipalGroupMembership = typeof PrincipalGroupMemberships.$inferSelect

/**
 * Adds a Principal to a static group.
 *
 * Computed groups reject manual membership because their effective membership
 * comes from CEL evaluation in the native engine.
 */
export async function addPrincipalToGroup(
  principalUid: string,
  groupId: string,
  db: QueryExecutor = DB
): Promise<void> {
  const principal = await fetchPrincipal(normalizeUid(principalUid), db)
  const group = await fetchGroup(groupId, db)

  if (group.kind === 'computed') throw new PrincipalDomainError('computed_group')

  await db
    .insert(PrincipalGroupMemberships)
    .values({
      principalUid: principal.uid,
      groupId: group.id
    })
    .onConflictDoNothing()
}

/**
 * Removes a Principal from a static group.
 *
 * Removing from the built-in admin group is guarded by both membership-count
 * and active-human-admin checks so an installation cannot lock itself out.
 */
export async function removePrincipalFromGroup(
  principalUid: string,
  groupId: string,
  db: QueryExecutor = DB
): Promise<void> {
  const principal = await fetchPrincipal(normalizeUid(principalUid), db)
  const group = await fetchGroup(groupId, db)

  if (group.kind === 'computed') throw new PrincipalDomainError('computed_group')

  if (group.builtIn && group.name === ADMIN_GROUP_NAME) {
    return db.transaction(async tx => {
      const lockedPrincipal = await lockPrincipal(principal.uid, tx)
      const lockedGroup = await lockGroup(group.id, tx)

      await ensureMembershipExists(lockedPrincipal.uid, lockedGroup.id, tx)
      await ensureNotLastAdminMember(lockedGroup.id, lockedPrincipal.uid, tx)
      await ensureNotLastActiveHumanAdmin(lockedGroup.id, lockedPrincipal.uid, tx)
      await deleteMembership(lockedPrincipal.uid, lockedGroup.id, tx)
    })
  }

  await deleteMembership(principal.uid, group.id, db)
}

/**
 * Checks whether disabling a Principal would remove the last active human admin.
 *
 * Non-human Principals and humans that are not admin members do not affect the
 * recovery/admin path and therefore pass through.
 */
export async function ensureCanDisablePrincipal(principalUid: string, db: QueryExecutor = DB): Promise<void> {
  const principal = await fetchPrincipal(normalizeUid(principalUid), db)
  if (principal.status === 'disabled' || principal.type === 'agent') return

  const [admin] = await db
    .select()
    .from(PrincipalGroups)
    .where(and(eq(PrincipalGroups.name, ADMIN_GROUP_NAME), eq(PrincipalGroups.builtIn, true)))
    .limit(1)

  if (!admin) return

  const [membership] = await db
    .select()
    .from(PrincipalGroupMemberships)
    .where(
      and(eq(PrincipalGroupMemberships.principalUid, principal.uid), eq(PrincipalGroupMemberships.groupId, admin.id))
    )
    .limit(1)

  if (!membership) return

  await ensureNotLastActiveHumanAdmin(admin.id, principal.uid, db)
}

/**
 * Returns whether the built-in admin group currently has any explicit member.
 *
 * Root initialization uses this as the "is the installation already claimed?"
 * check.
 */
export async function adminMemberExists(db: QueryExecutor = DB): Promise<boolean> {
  const [admin] = await db
    .select()
    .from(PrincipalGroups)
    .where(and(eq(PrincipalGroups.name, ADMIN_GROUP_NAME), eq(PrincipalGroups.builtIn, true)))
    .limit(1)

  if (!admin) return false

  const [membership] = await db
    .select()
    .from(PrincipalGroupMemberships)
    .where(eq(PrincipalGroupMemberships.groupId, admin.id))
    .limit(1)
  return membership !== undefined
}

/**
 * Inserts a membership edge without rechecking group kind.
 *
 * This is used by root initialization after it has locked and verified the
 * built-in admin group.
 */
export async function insertMembership(principalUid: string, groupId: string, db: QueryExecutor = DB): Promise<void> {
  await db
    .insert(PrincipalGroupMemberships)
    .values({
      principalUid: normalizeUid(principalUid),
      groupId
    })
    .onConflictDoNothing()
}

async function fetchPrincipal(uid: string, db: QueryExecutor): Promise<Principal> {
  const [principal] = await db.select().from(Principals).where(eq(Principals.uid, uid)).limit(1)
  if (!principal) throw new PrincipalDomainError('not_found')

  return principal
}

async function fetchGroup(groupId: string, db: QueryExecutor): Promise<typeof PrincipalGroups.$inferSelect> {
  const [group] = await db.select().from(PrincipalGroups).where(eq(PrincipalGroups.id, groupId)).limit(1)
  if (!group) throw new PrincipalDomainError('not_found')

  return group
}

async function lockPrincipal(uid: string, db: QueryExecutor): Promise<Principal> {
  const [principal] = await db.select().from(Principals).where(eq(Principals.uid, uid)).for('update').limit(1)
  if (!principal) throw new PrincipalDomainError('not_found')

  return principal
}

async function lockGroup(groupId: string, db: QueryExecutor): Promise<typeof PrincipalGroups.$inferSelect> {
  const [group] = await db.select().from(PrincipalGroups).where(eq(PrincipalGroups.id, groupId)).for('update').limit(1)
  if (!group) throw new PrincipalDomainError('not_found')

  return group
}

/**
 * Locks the membership being removed so concurrent admin-removal attempts
 * cannot both pass the safety checks against the same pre-delete state.
 */
async function ensureMembershipExists(principalUid: string, groupId: string, db: QueryExecutor): Promise<void> {
  const [membership] = await db
    .select()
    .from(PrincipalGroupMemberships)
    .where(
      and(eq(PrincipalGroupMemberships.principalUid, principalUid), eq(PrincipalGroupMemberships.groupId, groupId))
    )
    .for('update')
    .limit(1)

  if (!membership) throw new PrincipalDomainError('not_found')
}

/**
 * Preserves at least one admin membership edge.
 *
 * This catches the simple case where there would be no admin members at all,
 * even before considering whether the remaining members are active humans.
 */
async function ensureNotLastAdminMember(groupId: string, principalUid: string, db: QueryExecutor): Promise<void> {
  const rows = await db
    .select({ principalUid: PrincipalGroupMemberships.principalUid })
    .from(PrincipalGroupMemberships)
    .where(
      and(eq(PrincipalGroupMemberships.groupId, groupId), ne(PrincipalGroupMemberships.principalUid, principalUid))
    )
    .for('update')

  if (rows.length === 0) throw new PrincipalDomainError('last_admin_member')
}

/**
 * Preserves at least one active human admin after the pending change.
 */
async function ensureNotLastActiveHumanAdmin(groupId: string, principalUid: string, db: QueryExecutor): Promise<void> {
  const rows = await db
    .select({ principalUid: Principals.uid })
    .from(PrincipalGroupMemberships)
    .innerJoin(Principals, eq(Principals.uid, PrincipalGroupMemberships.principalUid))
    .where(
      and(
        eq(PrincipalGroupMemberships.groupId, groupId),
        ne(PrincipalGroupMemberships.principalUid, principalUid),
        eq(Principals.type, 'human'),
        eq(Principals.status, 'active')
      )
    )
    .for('update')

  if (rows.length === 0) throw new PrincipalDomainError('last_active_human_admin')
}

async function deleteMembership(principalUid: string, groupId: string, db: QueryExecutor): Promise<void> {
  const deleted = await db
    .delete(PrincipalGroupMemberships)
    .where(
      and(eq(PrincipalGroupMemberships.principalUid, principalUid), eq(PrincipalGroupMemberships.groupId, groupId))
    )
    .returning({ principalUid: PrincipalGroupMemberships.principalUid })

  if (deleted.length === 0) throw new PrincipalDomainError('not_found')
}
