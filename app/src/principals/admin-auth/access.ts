import { and, eq } from 'drizzle-orm'
import { DB } from '@/common/database'
import { PrincipalGroupMemberships, PrincipalGroups, Principals } from '@/common/db-schema'
import { ADMIN_GROUP_NAME } from '../authorization/groups'

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
