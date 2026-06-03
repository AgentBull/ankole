import { match, P } from '@pleisto/active-support'
import { and, eq } from 'drizzle-orm'
import { DB, jsonbParam } from '@/common/database'
import { type JsonObject, PrincipalExternalIdentities, Principals } from '@/common/db-schema'
import {
  newPrincipalId,
  normalizeUid,
  type Principal,
  PrincipalDomainError,
  trimOptionalText
} from '../principals/service'

export type PrincipalExternalIdentity = typeof PrincipalExternalIdentities.$inferSelect
export type PrincipalExternalIdentityKind = PrincipalExternalIdentity['kind']

export interface CreateExternalIdentityInput {
  principalUid: string
  kind: PrincipalExternalIdentityKind
  provider?: string | null
  adapter?: string | null
  channelId?: string | null
  externalId: string
  verifiedAt?: Date | null
  metadata?: JsonObject
}

/**
 * Persists an external provider identity binding for a Principal.
 *
 * V1 only resolves `channel_actor` for inbound actor lookup, but the same table
 * also stores future login/outbound bindings so identity uniqueness rules are
 * centralized from the start.
 */
export async function createExternalIdentity(input: CreateExternalIdentityInput): Promise<PrincipalExternalIdentity> {
  const attrs = normalizeExternalIdentityInput(input)

  const [identity] = await DB.insert(PrincipalExternalIdentities)
    .values({
      id: newPrincipalId(),
      ...attrs,
      metadata: jsonbParam(attrs.metadata ?? {})
    })
    .returning()

  return identity
}

/**
 * Resolves an inbound channel actor to the active human Principal it represents.
 *
 * Unverified bindings, disabled Principals, and agent Principals fail closed.
 * This keeps inbound user actions from silently becoming agent or stale-human
 * authority.
 */
export async function resolveChannelActor(adapter: string, channelId: string, externalId: string): Promise<Principal> {
  const adapterValue = requiredText(adapter, 'adapter')
  const channelIdValue = requiredText(channelId, 'channelId')
  const externalIdValue = requiredText(externalId, 'externalId')

  const [row] = await DB.select({ identity: PrincipalExternalIdentities, principal: Principals })
    .from(PrincipalExternalIdentities)
    .innerJoin(Principals, eq(Principals.uid, PrincipalExternalIdentities.principalUid))
    .where(
      and(
        eq(PrincipalExternalIdentities.kind, 'channel_actor'),
        eq(PrincipalExternalIdentities.adapter, adapterValue),
        eq(PrincipalExternalIdentities.channelId, channelIdValue),
        eq(PrincipalExternalIdentities.externalId, externalIdValue)
      )
    )
    .limit(1)

  return match(row)
    .with(P.nullish, () => {
      throw new PrincipalDomainError('not_found')
    })
    .when(
      ({ identity }) => !channelIdentityVerified(identity),
      () => {
        throw new PrincipalDomainError('forbidden', 'channel identity is not verified')
      }
    )
    .with({ principal: { status: P.not('active') } }, () => {
      throw new PrincipalDomainError('principal_disabled')
    })
    .with({ principal: { type: P.not('human') } }, () => {
      throw new PrincipalDomainError('not_human')
    })
    .otherwise(({ principal }) => principal)
}

/**
 * A channel actor binding is trusted only after verification.
 */
export function channelIdentityVerified(identity: PrincipalExternalIdentity | undefined | null): boolean {
  return identity?.verifiedAt instanceof Date
}

function normalizeExternalIdentityInput(
  input: CreateExternalIdentityInput
): Omit<typeof PrincipalExternalIdentities.$inferInsert, 'id'> {
  const externalId = requiredText(input.externalId, 'externalId')
  const metadata = input.metadata ?? {}

  if (!isJsonObject(metadata)) throw new PrincipalDomainError('invalid_request', 'metadata must be a JSON object')

  const attrs = {
    principalUid: normalizeUid(input.principalUid),
    kind: input.kind,
    provider: trimOptionalText(input.provider),
    adapter: trimOptionalText(input.adapter),
    channelId: trimOptionalText(input.channelId),
    externalId,
    verifiedAt: input.verifiedAt ?? null,
    metadata
  }

  if (attrs.kind === 'channel_actor' && (!attrs.adapter || !attrs.channelId)) {
    throw new PrincipalDomainError('invalid_request', 'channel actor identity requires adapter and channelId')
  }

  if ((attrs.kind === 'login_subject' || attrs.kind === 'outbound_actor') && !attrs.provider) {
    throw new PrincipalDomainError('invalid_request', `${attrs.kind} identity requires provider`)
  }

  return attrs
}

function requiredText(value: string, field: string): string {
  const normalized = trimOptionalText(value)
  if (!normalized) throw new PrincipalDomainError('invalid_request', `${field} must not be empty`)

  return normalized
}

function isJsonObject(value: unknown): value is JsonObject {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}
