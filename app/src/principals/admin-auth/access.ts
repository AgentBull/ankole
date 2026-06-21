import { and, eq } from 'drizzle-orm'
import { DB } from '@/common/database'
import { PrincipalGroupMemberships, PrincipalGroups, Principals } from '@/common/db-schema'
import { ADMIN_GROUP_NAME } from '../authorization/groups'

/**
 * Reports whether a Principal is allowed to use the admin console right now.
 *
 * This is the single gate the admin-auth surface trusts: it is checked on every
 * `/api/session` read and again right after OIDC login, so a Principal that was
 * removed from the admin group or disabled loses console access on the next
 * request even though their sealed session cookie is still valid.
 *
 * All four predicates must hold at once, which is why they are expressed as a
 * single joined query rather than separate lookups: the subject must be a human
 * (agents never log into the console), active (not disabled), and an explicit
 * member of the *built-in* admin group. `builtIn` is pinned so an operator
 * cannot grant console access by creating their own group also named "admin".
 */
export async function activeHumanAdmin(principalUid: string): Promise<boolean> {
  const [row] = await DB.select({ uid: Principals.uid })
    .from(Principals)
    .innerJoin(PrincipalGroupMemberships, eq(PrincipalGroupMemberships.principalUid, Principals.uid))
    .innerJoin(PrincipalGroups, eq(PrincipalGroups.id, PrincipalGroupMemberships.groupId))
    .where(
      and(
        eq(Principals.uid, principalUid),
        eq(Principals.type, 'human'),
        eq(Principals.status, 'active'),
        eq(PrincipalGroups.name, ADMIN_GROUP_NAME),
        eq(PrincipalGroups.builtIn, true)
      )
    )
    .limit(1)

  return row !== undefined
}
