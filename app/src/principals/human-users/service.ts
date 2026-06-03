import { eq } from 'drizzle-orm'
import { DB } from '@/common/database'
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

function normalizeEmail(value: string | null | undefined): string | null {
  const email = trimOptionalText(value)
  if (email === null) return null

  const normalized = email.toLowerCase()
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(normalized)) {
    throw new PrincipalDomainError('invalid_request', 'email is invalid')
  }

  return normalized
}

function normalizePhone(value: string | null | undefined): string | null {
  const phone = trimOptionalText(value)
  if (phone === null) return null

  if (!/^\+[1-9]\d{1,14}$/.test(phone)) throw new PrincipalDomainError('invalid_request', 'phone must be E.164')

  return phone
}
