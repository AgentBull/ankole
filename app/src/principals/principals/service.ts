import { genUUIDv7 } from '@agentbull/bullx-native-addons'
import { eq, sql } from 'drizzle-orm'
import { DB } from '@/common/database'
import { Principals } from '@/common/db-schema'

export type Principal = typeof Principals.$inferSelect
export type PrincipalStatus = Principal['status']
export type PrincipalType = Principal['type']

/**
 * Stable machine-readable reasons returned by Principal/AuthZ domain failures.
 *
 * Callers should branch on `reason`; `message` is for logs or developer-facing
 * context and is not a durable API contract.
 */
export type PrincipalErrorReason =
  | 'forbidden'
  | 'group_has_grants'
  | 'invalid_request'
  | 'last_active_human_admin'
  | 'last_admin_member'
  | 'not_found'
  | 'not_human'
  | 'not_agent'
  | 'principal_disabled'
  | 'root_init_closed'
  | 'built_in_group'
  | 'computed_group'
  | 'conflicting_built_in_group'

export class PrincipalDomainError extends Error {
  constructor(
    public readonly reason: PrincipalErrorReason,
    message: string = reason
  ) {
    super(message)
    this.name = 'PrincipalDomainError'
  }
}

/**
 * Normalizes the public Principal UID.
 *
 * UIDs are case-insensitive at the API edge and lowercase in storage. This is
 * the subject key used in grants, memberships, agent rows, and external
 * identities, so every write path must go through this normalization.
 */
export function normalizeUid(uid: string): string {
  const normalized = uid.trim().toLowerCase()
  if (!normalized) throw new PrincipalDomainError('invalid_request', 'uid must not be empty')

  return normalized
}

/**
 * Converts optional user-facing text to either trimmed text or null.
 *
 * Drizzle distinguishes undefined and null on inserts/updates; the Principal
 * domain stores absence as null so callers do not need to care about that
 * difference.
 */
export function trimOptionalText(value: string | null | undefined): string | null {
  if (value === undefined || value === null) return null

  const trimmed = value.trim()
  return trimmed === '' ? null : trimmed
}

/**
 * Generates UUIDv7 identifiers for Principal-domain rows that still need opaque
 * storage ids, such as groups, grants, and external identity bindings.
 *
 * UUIDv7 keeps row ids globally unique while preserving enough time order
 * to make operational inspection and default index locality better than UUIDv4.
 */
export function newPrincipalDomainRowId(): string {
  return genUUIDv7()
}

/**
 * Looks up a Principal by normalized UID.
 *
 * Missing rows return `undefined` rather than throwing because read paths often
 * use this as an existence check. Mutation and authorization paths throw domain
 * errors when absence changes behavior.
 */
export async function getPrincipal(uid: string): Promise<Principal | undefined> {
  const [principal] = await DB.select()
    .from(Principals)
    .where(eq(Principals.uid, normalizeUid(uid)))
    .limit(1)
  return principal
}

/**
 * Updates a Principal lifecycle status.
 *
 * The backend intentionally allows disabling the final active human admin. The
 * admin console can prevent accidental lockout at the UX layer without making
 * sync and recovery flows carry a stronger guarantee than the product needs.
 */
export async function updatePrincipalStatus(uid: string, status: PrincipalStatus): Promise<Principal> {
  if (status !== 'active' && status !== 'disabled') {
    throw new PrincipalDomainError('invalid_request', 'invalid principal status')
  }

  const principalUid = normalizeUid(uid)

  return DB.transaction(async tx => {
    // Lock the row for the duration of the transaction. Status changes can arrive
    // concurrently from directory sync and an operator action; serializing them
    // on the row keeps the final state deterministic rather than last-write-wins
    // across an interleaved read.
    const [principal] = await tx
      .select()
      .from(Principals)
      .where(eq(Principals.uid, principalUid))
      .for('update')
      .limit(1)

    if (!principal) throw new PrincipalDomainError('not_found')

    const [updated] = await tx
      .update(Principals)
      .set({
        status,
        updatedAt: sql`CURRENT_TIMESTAMP`
      })
      .where(eq(Principals.uid, principal.uid))
      .returning()

    if (!updated) throw new PrincipalDomainError('not_found')

    return updated
  })
}

/**
 * Convenience wrapper for the only destructive lifecycle transition currently
 * exposed by Principal/AuthZ.
 */
export async function disablePrincipal(uid: string): Promise<Principal> {
  return updatePrincipalStatus(uid, 'disabled')
}
