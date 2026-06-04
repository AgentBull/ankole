import { eq, sql } from 'drizzle-orm'
import { DB, type QueryExecutor } from '@/common/database'
import { HumanUsers, Principals } from '@/common/db-schema'
import {
  newPrincipalId,
  normalizeUid,
  type Principal,
  PrincipalDomainError,
  trimOptionalText
} from '../principals/service'

export type HumanUser = typeof HumanUsers.$inferSelect

export interface CreateHumanInput {
  uid: string
  displayName?: string | null
  avatarUrl?: string | null
  email?: string | null
  phone?: string | null
}

export interface CreateHumanResult {
  principal: Principal
  humanUser: HumanUser
}

/**
 * Creates a human Principal and its subtype row atomically.
 *
 * Email is trimmed/lowercased and phone must already be E.164. This function
 * does not create login subjects, activation records, or OIDC bindings; those
 * are separate flows layered on top of the Principal row.
 */
export async function createHuman(input: CreateHumanInput): Promise<CreateHumanResult> {
  const principalUid = normalizeUid(input.uid)
  const email = normalizeEmail(input.email)
  const phone = normalizePhone(input.phone)

  return DB.transaction(async tx => {
    const [principal] = await tx
      .insert(Principals)
      .values({
        id: newPrincipalId(),
        uid: principalUid,
        type: 'human',
        status: 'active',
        displayName: trimOptionalText(input.displayName),
        avatarUrl: trimOptionalText(input.avatarUrl)
      })
      .returning()

    const [humanUser] = await tx
      .insert(HumanUsers)
      .values({
        principalUid: principal.uid,
        email,
        phone
      })
      .returning()

    return { principal, humanUser }
  })
}

/**
 * Returns the human subtype row for a Principal UID.
 */
export async function getHumanUser(principalUid: string): Promise<HumanUser | undefined> {
  const [humanUser] = await DB.select()
    .from(HumanUsers)
    .where(eq(HumanUsers.principalUid, normalizeUid(principalUid)))
    .limit(1)
  return humanUser
}

export function normalizeEmail(value: string | null | undefined): string | null {
  const email = trimOptionalText(value)
  if (email === null) return null

  const normalized = email.toLowerCase()
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(normalized)) {
    throw new PrincipalDomainError('invalid_request', 'email is invalid')
  }

  return normalized
}

export function normalizePhone(value: string | null | undefined): string | null {
  const phone = trimOptionalText(value)
  if (phone === null) return null

  if (!/^\+[1-9]\d{1,14}$/.test(phone)) throw new PrincipalDomainError('invalid_request', 'phone must be E.164')

  return phone
}

/**
 * Upserts profile fields from an external identity observation.
 *
 * This function intentionally does not change Principal status. The sync layer
 * decides whether a user should be disabled or restored because it has the
 * provider metadata needed to distinguish provider-driven disables from manual
 * operator disables.
 *
 * `undefined` means "this observation did not carry the field" and preserves an
 * existing value on update. `null` means "the provider explicitly has no value"
 * and clears the field. This matters because chat events usually contain a name
 * and avatar but not email/phone, while directory sync is authoritative for
 * contact details.
 */
export async function upsertHumanProfile(input: CreateHumanInput, db: QueryExecutor = DB): Promise<CreateHumanResult> {
  const principalUid = normalizeUid(input.uid)
  const email = normalizeEmail(input.email)
  const phone = normalizePhone(input.phone)

  const [existing] = await db.select().from(Principals).where(eq(Principals.uid, principalUid)).limit(1)
  if (!existing) {
    const [principal] = await db
      .insert(Principals)
      .values({
        id: newPrincipalId(),
        uid: principalUid,
        type: 'human',
        status: 'active',
        displayName: trimOptionalText(input.displayName),
        avatarUrl: trimOptionalText(input.avatarUrl)
      })
      .returning()

    const [humanUser] = await db
      .insert(HumanUsers)
      .values({
        principalUid: principal.uid,
        email,
        phone
      })
      .returning()

    return { principal, humanUser }
  }

  if (existing.type !== 'human') throw new PrincipalDomainError('not_human')

  const [principal] = await db
    .update(Principals)
    .set({
      displayName:
        input.displayName === undefined ? sql`${Principals.displayName}` : trimOptionalText(input.displayName),
      avatarUrl: input.avatarUrl === undefined ? sql`${Principals.avatarUrl}` : trimOptionalText(input.avatarUrl),
      updatedAt: new Date()
    })
    .where(eq(Principals.uid, existing.uid))
    .returning()

  const [humanUser] = await db
    .insert(HumanUsers)
    .values({
      principalUid: principal.uid,
      email,
      phone
    })
    .onConflictDoUpdate({
      target: HumanUsers.principalUid,
      set: {
        email: input.email === undefined ? sql`${HumanUsers.email}` : email,
        phone: input.phone === undefined ? sql`${HumanUsers.phone}` : phone,
        updatedAt: new Date()
      }
    })
    .returning()

  return { principal, humanUser }
}
