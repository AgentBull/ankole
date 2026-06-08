import { match, P } from '@pleisto/active-support'
import { bullxExternalIdentityNamespaceIdPattern } from '@agentbull/bullx-sdk/plugins'
import { and, eq } from 'drizzle-orm'
import { DB, jsonbParam, type QueryExecutor } from '@/common/database'
import { type JsonObject, PrincipalExternalIdentities, Principals } from '@/common/db-schema'
import { isJsonObject, jsonObject } from '@/common/json'
import { upsertHumanProfile } from '../human-users/service'
import {
  newPrincipalDomainRowId,
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

export interface UpsertPlatformSubjectHumanInput {
  /**
   * External platform namespace stored in `principal_external_identities.provider`.
   *
   * This is a platform/tenant namespace, not a channel id and not a runtime
   * pointer to another adapter. For Lark it should be shared by all chat apps
   * that want Lark `user_id` to identify the same human.
   */
  provider: string
  /**
   * Subject id inside the provider namespace. For Lark this is `user_id`.
   */
  externalId: string
  /**
   * Optional UID to use only when no platform subject binding exists yet.
   *
   * Callers normally omit this and let BullX default to the normalized external
   * id. Once a binding exists, the binding's `principal_uid` is authoritative.
   */
  uid?: string | null
  displayName?: string | null
  avatarUrl?: string | null
  email?: string | null
  phone?: string | null
  verifiedAt?: Date | null
  metadata?: JsonObject
}

export interface UpsertPlatformSubjectHumanResult {
  principal: Principal
  identity: PrincipalExternalIdentity
}

/**
 * Persists an external provider identity binding for a Principal.
 *
 * `channel_actor` is still available for channel-only integrations, while
 * `platform_subject` stores a provider-scoped platform subject such as Lark
 * `user_id`. Login, directory sync, chat observation, and future outbound lookup
 * can all add evidence to that same subject, but no producer owns the whole row.
 */
export async function createExternalIdentity(input: CreateExternalIdentityInput): Promise<PrincipalExternalIdentity> {
  const attrs = normalizeExternalIdentityInput(input)

  const [identity] = await DB.insert(PrincipalExternalIdentities)
    .values({
      id: newPrincipalDomainRowId(),
      ...attrs,
      metadata: jsonbParam(attrs.metadata ?? {})
    })
    .returning()

  return identity
}

export async function upsertExternalIdentity(
  input: CreateExternalIdentityInput,
  db: QueryExecutor = DB
): Promise<PrincipalExternalIdentity> {
  const attrs = normalizeExternalIdentityInput(input)
  const [existing] = await db
    .select()
    .from(PrincipalExternalIdentities)
    .where(identityLookupCondition(attrs.kind, attrs))
    .limit(1)

  if (existing) {
    const [updated] = await db
      .update(PrincipalExternalIdentities)
      .set({
        principalUid: attrs.principalUid,
        provider: attrs.provider,
        adapter: attrs.adapter,
        channelId: attrs.channelId,
        externalId: attrs.externalId,
        verifiedAt: attrs.verifiedAt,
        metadata: jsonbParam(attrs.metadata ?? {}),
        updatedAt: new Date()
      })
      .where(eq(PrincipalExternalIdentities.id, existing.id))
      .returning()

    return updated
  }

  const [identity] = await db
    .insert(PrincipalExternalIdentities)
    .values({
      id: newPrincipalDomainRowId(),
      ...attrs,
      metadata: jsonbParam(attrs.metadata ?? {})
    })
    .returning()

  return identity
}

/**
 * Upserts the shared human binding for a platform-scoped external subject.
 *
 * This is the database-level convergence point for platform subjects. A Lark
 * chat event and a Lark directory sync do not call each other; when both observe
 * the same `provider + user_id`, the unique `platform_subject` binding makes the
 * observations converge on one Principal.
 */
export async function upsertPlatformSubjectHuman(
  input: UpsertPlatformSubjectHumanInput,
  db: QueryExecutor = DB
): Promise<UpsertPlatformSubjectHumanResult> {
  return db.transaction(async tx => upsertPlatformSubjectHumanInExecutor(input, tx))
}

/**
 * Resolves a provider-scoped human subject such as `lark-main + user_id`.
 *
 * This is intentionally separate from `resolveChannelActor`: provider subjects
 * survive multiple bot apps/channels inside the same enterprise tenant, while
 * channel actors are scoped to a specific adapter/channel projection.
 */
export async function resolvePlatformSubject(provider: string, externalId: string): Promise<Principal> {
  const providerValue = requiredProvider(provider, 'provider')
  const externalIdValue = requiredText(externalId, 'externalId')

  const [row] = await DB.select({ identity: PrincipalExternalIdentities, principal: Principals })
    .from(PrincipalExternalIdentities)
    .innerJoin(Principals, eq(Principals.uid, PrincipalExternalIdentities.principalUid))
    .where(
      and(
        eq(PrincipalExternalIdentities.kind, 'platform_subject'),
        eq(PrincipalExternalIdentities.provider, providerValue),
        eq(PrincipalExternalIdentities.externalId, externalIdValue)
      )
    )
    .limit(1)

  return match(row)
    .with(P.nullish, () => {
      throw new PrincipalDomainError('not_found')
    })
    .with({ principal: { status: P.not('active') } }, () => {
      throw new PrincipalDomainError('principal_disabled')
    })
    .with({ principal: { type: P.not('human') } }, () => {
      throw new PrincipalDomainError('not_human')
    })
    .otherwise(({ principal }) => principal)
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

async function upsertPlatformSubjectHumanInExecutor(
  input: UpsertPlatformSubjectHumanInput,
  db: QueryExecutor
): Promise<UpsertPlatformSubjectHumanResult> {
  const provider = requiredProvider(input.provider, 'provider')
  const externalId = requiredText(input.externalId, 'externalId')
  const metadata = input.metadata ?? {}
  if (!isJsonObject(metadata)) throw new PrincipalDomainError('invalid_request', 'metadata must be a JSON object')

  const [existingIdentity] = await db
    .select()
    .from(PrincipalExternalIdentities)
    .where(
      and(
        eq(PrincipalExternalIdentities.kind, 'platform_subject'),
        eq(PrincipalExternalIdentities.provider, provider),
        eq(PrincipalExternalIdentities.externalId, externalId)
      )
    )
    .limit(1)

  const principalUid = existingIdentity?.principalUid ?? normalizeUid(input.uid ?? externalId)
  const { principal } = await upsertHumanProfile(
    {
      uid: principalUid,
      displayName: input.displayName,
      avatarUrl: input.avatarUrl,
      email: input.email,
      phone: input.phone
    },
    db
  )
  const mergedMetadata = {
    ...metadataObject(existingIdentity?.metadata),
    ...metadata,
    provider,
    externalId
  } satisfies JsonObject
  const identity = await upsertExternalIdentity(
    {
      principalUid: principal.uid,
      kind: 'platform_subject',
      provider,
      externalId,
      verifiedAt: input.verifiedAt ?? new Date(),
      metadata: mergedMetadata
    },
    db
  )

  return { principal, identity }
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

  if (
    (attrs.kind === 'platform_subject' || attrs.kind === 'login_subject' || attrs.kind === 'outbound_actor') &&
    !attrs.provider
  ) {
    throw new PrincipalDomainError('invalid_request', `${attrs.kind} identity requires provider`)
  }

  if (attrs.provider) requiredProvider(attrs.provider, 'provider')

  return attrs
}

function identityLookupCondition(
  kind: PrincipalExternalIdentityKind,
  attrs: Omit<typeof PrincipalExternalIdentities.$inferInsert, 'id'>
) {
  if (kind === 'channel_actor') {
    return and(
      eq(PrincipalExternalIdentities.kind, kind),
      eq(PrincipalExternalIdentities.adapter, attrs.adapter ?? ''),
      eq(PrincipalExternalIdentities.channelId, attrs.channelId ?? ''),
      eq(PrincipalExternalIdentities.externalId, attrs.externalId ?? '')
    )
  }

  return and(
    eq(PrincipalExternalIdentities.kind, kind),
    eq(PrincipalExternalIdentities.provider, attrs.provider ?? ''),
    eq(PrincipalExternalIdentities.externalId, attrs.externalId ?? '')
  )
}

function requiredText(value: string, field: string): string {
  const normalized = trimOptionalText(value)
  if (!normalized) throw new PrincipalDomainError('invalid_request', `${field} must not be empty`)

  return normalized
}

function requiredProvider(value: string | null | undefined, field: string): string {
  const normalized = trimOptionalText(value)
  if (!normalized) throw new PrincipalDomainError('invalid_request', `${field} must not be empty`)
  if (!bullxExternalIdentityNamespaceIdPattern.test(normalized)) {
    throw new PrincipalDomainError('invalid_request', `${field} must match ${bullxExternalIdentityNamespaceIdPattern}`)
  }

  return normalized
}

function metadataObject(value: unknown): JsonObject {
  return jsonObject(value) ?? {}
}
