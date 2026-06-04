import type {
  BullXIdentityProviderFullSyncSnapshot,
  BullXIdentityProviderGroupRecord,
  BullXIdentityProviderUserRecord
} from '@agentbull/bullx-sdk/plugins'
import { bullxExternalIdentityNamespaceIdPattern } from '@agentbull/bullx-sdk/plugins'
import { and, eq, inArray, sql } from 'drizzle-orm'
import { DB, jsonbParam, type QueryExecutor } from '@/common/database'
import {
  type JsonObject,
  PrincipalExternalIdentities,
  PrincipalGroupExternalBindings,
  PrincipalGroupMemberships,
  PrincipalGroups,
  Principals
} from '@/common/db-schema'
import { upsertPlatformSubjectHuman } from '../external-identities/service'
import { newPrincipalDomainRowId, normalizeUid, PrincipalDomainError, trimOptionalText } from '../principals/service'

const PROVIDER_DISABLED_METADATA_KEY = 'bullxDisabledByProvider'

export interface IdentityProviderSyncStats {
  usersUpserted: number
  usersDisabled: number
  groupsUpserted: number
  groupsDeleted: number
  membershipsUpserted: number
}

export interface IdentityProviderUserSyncResult {
  principalUid: string
  membershipsUpserted: number
}

/**
 * Applies a provider's authoritative startup snapshot.
 *
 * The identity provider is treated as the source of truth for its own
 * platform subjects and department memberships. Rows from other providers, and
 * non-provider Principal groups, are deliberately left untouched.
 */
export async function applyIdentityProviderFullSync(
  providerId: string,
  snapshot: BullXIdentityProviderFullSyncSnapshot
): Promise<IdentityProviderSyncStats> {
  const provider = requiredProviderId(providerId, 'providerId')
  return DB.transaction(async tx => {
    const stats: IdentityProviderSyncStats = {
      usersUpserted: 0,
      usersDisabled: 0,
      groupsUpserted: 0,
      groupsDeleted: 0,
      membershipsUpserted: 0
    }

    for (const group of snapshot.groups) {
      await upsertIdentityProviderGroup(provider, group, tx)
      stats.groupsUpserted += 1
    }

    const seenGroupIds = new Set(snapshot.groups.map(group => group.externalId))
    stats.groupsDeleted += await deleteMissingIdentityProviderGroups(provider, seenGroupIds, tx)
    const groupContext = await loadIdentityProviderGroupContext(provider, tx)

    for (const user of snapshot.users) {
      const principalUid = await upsertIdentityProviderUser(provider, user, tx)
      stats.usersUpserted += 1
      if (user.status === 'disabled') continue

      stats.membershipsUpserted += await replaceIdentityProviderMemberships(
        provider,
        principalUid,
        user.departmentExternalIds ?? [],
        tx,
        groupContext
      )
    }

    const seenUserIds = new Set(snapshot.users.map(user => user.externalId))
    stats.usersDisabled += await disableMissingIdentityProviderUsers(provider, seenUserIds, tx)

    return stats
  })
}

/**
 * Applies a single user change from an incremental provider event.
 *
 * Lark contact user events can carry department changes, so this path updates
 * the human profile, the shared platform identity, and the provider-owned
 * group memberships together. Without this, WebSocket sync would refresh names
 * and status but leave authorization groups stale until the next full sync.
 */
export async function syncIdentityProviderUser(
  providerId: string,
  user: BullXIdentityProviderUserRecord
): Promise<IdentityProviderUserSyncResult> {
  const provider = requiredProviderId(providerId, 'providerId')
  return DB.transaction(async tx => {
    const principalUid = await upsertIdentityProviderUser(provider, user, tx)
    const membershipsUpserted =
      user.status === 'disabled'
        ? 0
        : await replaceIdentityProviderMemberships(provider, principalUid, user.departmentExternalIds ?? [], tx)

    return { principalUid, membershipsUpserted }
  })
}

export async function upsertIdentityProviderUser(
  providerId: string,
  user: BullXIdentityProviderUserRecord,
  db: QueryExecutor = DB
): Promise<string> {
  const provider = requiredProviderId(providerId, 'providerId')
  const externalId = requiredText(user.externalId, 'externalId')
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

  const existingMetadata = metadataObject(existingIdentity?.metadata)
  const disabledByProvider = existingMetadata[PROVIDER_DISABLED_METADATA_KEY] === true
  const activeMetadata = {
    ...metadataObject(user.metadata),
    provider,
    externalId,
    syncedAt: new Date().toISOString()
  } satisfies JsonObject

  if (user.status === 'disabled') {
    const { principal } = await upsertPlatformSubjectHuman(
      {
        provider,
        externalId,
        uid: existingIdentity?.principalUid ?? externalId,
        displayName: user.displayName,
        avatarUrl: user.avatarUrl,
        email: user.email,
        phone: user.phone,
        verifiedAt: new Date(),
        metadata: {
          ...activeMetadata,
          [PROVIDER_DISABLED_METADATA_KEY]: true
        }
      },
      db
    )
    await updatePrincipalStatusInExecutor(principal.uid, 'disabled', db)
    await clearIdentityProviderMemberships(provider, principal.uid, db)
    return principal.uid
  }

  const { principal } = await upsertPlatformSubjectHuman(
    {
      provider,
      externalId,
      uid: existingIdentity?.principalUid ?? externalId,
      displayName: user.displayName,
      avatarUrl: user.avatarUrl,
      email: user.email,
      phone: user.phone,
      verifiedAt: new Date(),
      metadata: {
        ...activeMetadata,
        [PROVIDER_DISABLED_METADATA_KEY]: false
      }
    },
    db
  )
  if (disabledByProvider) await updatePrincipalStatusInExecutor(principal.uid, 'active', db)

  return principal.uid
}

export async function disableIdentityProviderUser(
  providerId: string,
  externalId: string,
  metadata: { [key: string]: unknown } = {},
  db: QueryExecutor = DB
): Promise<void> {
  const provider = requiredProviderId(providerId, 'providerId')
  const externalIdValue = requiredText(externalId, 'externalId')
  const [identity] = await db
    .select()
    .from(PrincipalExternalIdentities)
    .where(
      and(
        eq(PrincipalExternalIdentities.kind, 'platform_subject'),
        eq(PrincipalExternalIdentities.provider, provider),
        eq(PrincipalExternalIdentities.externalId, externalIdValue)
      )
    )
    .limit(1)

  if (!identity) return

  await updatePrincipalStatusInExecutor(identity.principalUid, 'disabled', db)
  await clearIdentityProviderMemberships(provider, identity.principalUid, db)
  await db
    .update(PrincipalExternalIdentities)
    .set({
      metadata: jsonbParam({
        ...metadataObject(identity.metadata),
        ...metadataObject(metadata),
        [PROVIDER_DISABLED_METADATA_KEY]: true,
        disabledAt: new Date().toISOString()
      }),
      updatedAt: sql`CURRENT_TIMESTAMP`
    })
    .where(eq(PrincipalExternalIdentities.id, identity.id))
}

async function clearIdentityProviderMemberships(
  providerId: string,
  principalUid: string,
  db: QueryExecutor
): Promise<void> {
  const groupContext = await loadIdentityProviderGroupContext(providerId, db)
  if (groupContext.providerGroupIds.length === 0) return

  await db
    .delete(PrincipalGroupMemberships)
    .where(
      and(
        eq(PrincipalGroupMemberships.principalUid, principalUid),
        inArray(PrincipalGroupMemberships.groupId, groupContext.providerGroupIds)
      )
    )
}

export async function upsertIdentityProviderGroup(
  providerId: string,
  group: BullXIdentityProviderGroupRecord,
  db: QueryExecutor = DB
): Promise<string> {
  const provider = requiredProviderId(providerId, 'providerId')
  const externalId = requiredText(group.externalId, 'externalId')
  const [binding] = await db
    .select()
    .from(PrincipalGroupExternalBindings)
    .where(
      and(
        eq(PrincipalGroupExternalBindings.provider, provider),
        eq(PrincipalGroupExternalBindings.externalId, externalId)
      )
    )
    .limit(1)

  if (binding) {
    await db
      .update(PrincipalGroups)
      .set({
        description: group.description ?? group.name,
        updatedAt: sql`CURRENT_TIMESTAMP`
      })
      .where(eq(PrincipalGroups.id, binding.groupId))
    await updateGroupBinding(provider, externalId, binding.groupId, group, db)
    return binding.groupId
  }

  const name = externalGroupName(provider, externalId)
  const [existingGroup] = await db.select().from(PrincipalGroups).where(eq(PrincipalGroups.name, name)).limit(1)
  const groupId = existingGroup?.id ?? newPrincipalDomainRowId()

  if (!existingGroup) {
    await db.insert(PrincipalGroups).values({
      id: groupId,
      name,
      kind: 'static',
      description: group.description ?? group.name,
      computedCondition: null,
      builtIn: false
    })
  }

  await updateGroupBinding(provider, externalId, groupId, group, db)
  return groupId
}

export async function deleteIdentityProviderGroup(
  providerId: string,
  externalId: string,
  db: QueryExecutor = DB
): Promise<void> {
  const provider = requiredProviderId(providerId, 'providerId')
  const externalIdValue = requiredText(externalId, 'externalId')
  const [binding] = await db
    .select()
    .from(PrincipalGroupExternalBindings)
    .where(
      and(
        eq(PrincipalGroupExternalBindings.provider, provider),
        eq(PrincipalGroupExternalBindings.externalId, externalIdValue)
      )
    )
    .limit(1)

  if (!binding) return

  await db.delete(PrincipalGroupMemberships).where(eq(PrincipalGroupMemberships.groupId, binding.groupId))
  await db
    .delete(PrincipalGroupExternalBindings)
    .where(
      and(
        eq(PrincipalGroupExternalBindings.provider, provider),
        eq(PrincipalGroupExternalBindings.externalId, externalIdValue)
      )
    )
}

async function replaceIdentityProviderMemberships(
  providerId: string,
  principalUid: string,
  directExternalGroupIds: readonly string[],
  db: QueryExecutor,
  context?: IdentityProviderGroupMembershipContext
): Promise<number> {
  const groupContext = context ?? (await loadIdentityProviderGroupContext(providerId, db))
  const { bindingsByExternalId, providerGroupIds } = groupContext

  if (providerGroupIds.length > 0) {
    await db
      .delete(PrincipalGroupMemberships)
      .where(
        and(
          eq(PrincipalGroupMemberships.principalUid, principalUid),
          inArray(PrincipalGroupMemberships.groupId, providerGroupIds)
        )
      )
  }

  const targetGroupIds = new Set<string>()
  for (const externalGroupId of directExternalGroupIds) {
    for (const expandedExternalId of expandGroupAncestors(externalGroupId, bindingsByExternalId)) {
      const binding = bindingsByExternalId.get(expandedExternalId)
      if (binding) targetGroupIds.add(binding.groupId)
    }
  }

  for (const groupId of targetGroupIds) {
    await db
      .insert(PrincipalGroupMemberships)
      .values({
        principalUid,
        groupId
      })
      .onConflictDoNothing()
  }

  return targetGroupIds.size
}

interface IdentityProviderGroupMembershipContext {
  bindingsByExternalId: Map<string, typeof PrincipalGroupExternalBindings.$inferSelect>
  providerGroupIds: string[]
}

async function loadIdentityProviderGroupContext(
  providerId: string,
  db: QueryExecutor
): Promise<IdentityProviderGroupMembershipContext> {
  const provider = requiredProviderId(providerId, 'providerId')
  const bindings = await db
    .select()
    .from(PrincipalGroupExternalBindings)
    .where(eq(PrincipalGroupExternalBindings.provider, provider))

  return {
    bindingsByExternalId: new Map(bindings.map(binding => [binding.externalId, binding])),
    providerGroupIds: bindings.map(binding => binding.groupId)
  }
}

async function disableMissingIdentityProviderUsers(
  providerId: string,
  seenExternalIds: ReadonlySet<string>,
  db: QueryExecutor
): Promise<number> {
  const rows = await db
    .select()
    .from(PrincipalExternalIdentities)
    .where(
      and(
        eq(PrincipalExternalIdentities.kind, 'platform_subject'),
        eq(PrincipalExternalIdentities.provider, providerId)
      )
    )

  let disabled = 0
  for (const row of rows) {
    if (!identityProviderHasManagedUser(row.metadata)) continue

    if (row.externalId && !seenExternalIds.has(row.externalId)) {
      await disableIdentityProviderUser(providerId, row.externalId, { missingFromFullSync: true }, db)
      disabled += 1
    }
  }

  return disabled
}

async function deleteMissingIdentityProviderGroups(
  providerId: string,
  seenExternalIds: ReadonlySet<string>,
  db: QueryExecutor
): Promise<number> {
  const rows = await db
    .select()
    .from(PrincipalGroupExternalBindings)
    .where(eq(PrincipalGroupExternalBindings.provider, providerId))

  let deleted = 0
  for (const row of rows) {
    if (!seenExternalIds.has(row.externalId)) {
      await deleteIdentityProviderGroup(providerId, row.externalId, db)
      deleted += 1
    }
  }

  return deleted
}

async function updateGroupBinding(
  provider: string,
  externalId: string,
  groupId: string,
  group: BullXIdentityProviderGroupRecord,
  db: QueryExecutor
): Promise<void> {
  const metadata = {
    ...metadataObject(group.metadata),
    provider,
    externalId,
    name: group.name,
    parentExternalId: group.parentExternalId ?? null,
    status: group.status ?? 'active',
    syncedAt: new Date().toISOString()
  } satisfies JsonObject

  await db
    .insert(PrincipalGroupExternalBindings)
    .values({
      provider,
      externalId,
      groupId,
      metadata: jsonbParam(metadata)
    })
    .onConflictDoUpdate({
      target: [PrincipalGroupExternalBindings.provider, PrincipalGroupExternalBindings.externalId],
      set: {
        groupId,
        metadata: jsonbParam(metadata),
        updatedAt: sql`CURRENT_TIMESTAMP`
      }
    })
}

async function updatePrincipalStatusInExecutor(
  principalUid: string,
  status: 'active' | 'disabled',
  db: QueryExecutor
): Promise<void> {
  await db
    .update(Principals)
    .set({
      status,
      updatedAt: sql`CURRENT_TIMESTAMP`
    })
    .where(eq(Principals.uid, normalizeUid(principalUid)))
}

function expandGroupAncestors(
  externalGroupId: string,
  bindingsByExternalId: ReadonlyMap<string, typeof PrincipalGroupExternalBindings.$inferSelect>
): string[] {
  const expanded: string[] = []
  const visited = new Set<string>()
  let current: string | undefined = externalGroupId

  while (current && !visited.has(current)) {
    visited.add(current)
    expanded.push(current)
    const binding = bindingsByExternalId.get(current)
    current = stringMetadataValue(binding?.metadata, 'parentExternalId') ?? undefined
  }

  return expanded
}

function externalGroupName(providerId: string, externalId: string): string {
  return `${providerId}:department:${externalId}`.trim().toLowerCase()
}

function requiredText(value: string | null | undefined, field: string): string {
  const normalized = trimOptionalText(value)
  if (!normalized) throw new PrincipalDomainError('invalid_request', `${field} must not be empty`)

  return normalized
}

function requiredProviderId(value: string | null | undefined, field: string): string {
  const normalized = requiredText(value, field)
  if (!bullxExternalIdentityNamespaceIdPattern.test(normalized)) {
    throw new PrincipalDomainError('invalid_request', `${field} must match ${bullxExternalIdentityNamespaceIdPattern}`)
  }

  return normalized
}

function metadataObject(value: unknown): JsonObject {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) return {}

  return value as JsonObject
}

/**
 * Full sync can only disable subjects this provider has previously managed.
 *
 * Chat Gateway may create the same `platform_subject` row from a message before
 * any login/directory sync sees that user. Absence from a directory full sync is
 * therefore authoritative only for rows carrying provider-sync evidence.
 */
function identityProviderHasManagedUser(metadata: unknown): boolean {
  const value = metadataObject(metadata)
  return typeof value.syncedAt === 'string' || typeof value[PROVIDER_DISABLED_METADATA_KEY] === 'boolean'
}

function stringMetadataValue(metadata: unknown, key: string): string | null {
  const object = metadataObject(metadata)
  const value = object[key]
  return typeof value === 'string' && value.length > 0 ? value : null
}
