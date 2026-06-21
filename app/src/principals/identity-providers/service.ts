import type {
  BullXIdentityProviderFullSyncSnapshot,
  BullXIdentityProviderGroupRecord,
  BullXIdentityProviderUserRecord
} from '@agentbull/bullx-sdk/plugins'
import { bullxExternalIdentityNamespaceIdPattern } from '@agentbull/bullx-sdk/plugins'
import { and, eq, inArray, sql } from 'drizzle-orm'
import { DB, jsonbParam, type QueryExecutor } from '@/common/database'
import { jsonObject } from '@/common/json'
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

// Marker stored on a platform-subject identity's metadata recording that the
// directory provider (not an operator) disabled this user. It lets a later sync
// distinguish "the provider re-enabled them" from "an operator disabled them
// manually" and reactivate only in the former case.
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

    // Order matters. Groups are reconciled first so that when users are upserted
    // the group bindings (and their parent links) already exist; otherwise
    // ancestor membership expansion below would miss departments created in the
    // same snapshot.
    for (const group of snapshot.groups) {
      await upsertIdentityProviderGroup(provider, group, tx)
      stats.groupsUpserted += 1
    }

    const seenGroupIds = new Set(snapshot.groups.map(group => group.externalId))
    stats.groupsDeleted += await deleteMissingIdentityProviderGroups(provider, seenGroupIds, tx)
    // Load the now-current binding/parent map once and thread it through every
    // membership replace below, instead of re-querying per user.
    const groupContext = await loadIdentityProviderGroupContext(provider, tx)

    for (const user of snapshot.users) {
      const principalUid = await upsertIdentityProviderUser(provider, user, tx)
      stats.usersUpserted += 1
      // A disabled user keeps no group memberships; the upsert above already
      // cleared them, so skip the membership replace entirely.
      if (user.status === 'disabled') continue

      stats.membershipsUpserted += await replaceIdentityProviderMemberships(
        provider,
        principalUid,
        user.departmentExternalIds ?? [],
        tx,
        groupContext
      )
    }

    // Anything this provider previously managed but did not appear in this
    // snapshot is now absent from the directory, so disable it. Runs last so a
    // user moved between departments is re-upserted (and thus "seen") first.
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

/**
 * Idempotently upserts one directory user into its platform-subject Principal.
 *
 * Keyed on the stable `provider + externalId` platform subject, so repeated full
 * or incremental syncs converge on the same Principal rather than creating
 * duplicates. Returns the resolved principal uid for membership wiring.
 *
 * Reactivation is conditional: a user that comes back as `active` is re-enabled
 * only if BullX itself had marked it disabled-by-provider. This avoids overriding
 * a deliberate operator disable just because the directory still lists the user.
 */
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
  // `syncedAt` is the provider-sync evidence that later lets full sync treat
  // absence as authoritative (see `identityProviderHasManagedUser`).
  const activeMetadata = {
    ...metadataObject(user.metadata),
    provider,
    externalId,
    syncedAt: new Date().toISOString()
  } satisfies JsonObject

  if (user.status === 'disabled') {
    // Still upsert the profile so name/avatar stay current on a disabled user,
    // but stamp the disabled-by-provider marker, force the Principal to disabled,
    // and strip its provider-owned memberships. `uid` only takes effect when no
    // binding exists yet; an existing binding's principal uid wins.
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
  // Only flip status back to active if BullX had disabled this user on the
  // provider's behalf. A user the operator disabled by hand carries no such
  // marker and is left disabled even though the directory still lists them.
  if (disabledByProvider) await updatePrincipalStatusInExecutor(principal.uid, 'active', db)

  return principal.uid
}

/**
 * Disables a single platform subject in response to a provider event or a
 * missing-from-full-sync sweep.
 *
 * Sets the Principal to disabled, drops its provider-owned memberships, and
 * records the disabled-by-provider marker plus a timestamp on the identity so a
 * later reactivation can be attributed correctly. A no-op when no such identity
 * exists, because there is nothing this provider manages to disable.
 */
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

/**
 * Removes a principal's memberships in groups owned by this provider only.
 *
 * Scoping the delete to `providerGroupIds` is deliberate: memberships in
 * non-provider groups (manual ops grants, other providers' departments) must
 * survive a directory disable or department change.
 */
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

/**
 * Idempotently upserts a provider department into a BullX `static` group.
 *
 * A department maps to one group via a `provider + externalId` binding. When the
 * binding already exists it just refreshes the group and binding; otherwise it
 * either adopts an existing group with the deterministic external name or creates
 * a fresh one. Returns the group id so memberships can target it.
 */
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

  // No binding yet. Adopt a group already carrying this provider's deterministic
  // department name if one exists (e.g. left over from a prior sync whose binding
  // was lost), otherwise mint a new group id. This keeps re-sync from creating
  // duplicate department groups.
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

/**
 * Removes a provider department: drops all its memberships and the binding.
 *
 * Only the membership rows and the external binding are deleted, not the
 * underlying `PrincipalGroups` row; leaving the group avoids cascading away any
 * grants attached to it should the department reappear. A no-op when the
 * department was never bound here.
 */
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

/**
 * Resets a principal's provider-owned department memberships to match a fresh
 * list of direct departments.
 *
 * Implemented as "delete all of this provider's memberships for the user, then
 * insert the new target set" rather than a diff, because it is simpler and the
 * provider is authoritative for its own departments. Direct departments are
 * expanded up the parent chain so a member of a leaf department is also a member
 * of its ancestor org units, letting grants target either level.
 *
 * The delete is scoped to `providerGroupIds`, so memberships in non-provider
 * groups are untouched. Returns the number of target groups joined.
 */
async function replaceIdentityProviderMemberships(
  providerId: string,
  principalUid: string,
  directExternalGroupIds: readonly string[],
  db: QueryExecutor,
  context?: IdentityProviderGroupMembershipContext
): Promise<number> {
  // Callers inside a full sync pass a preloaded context to avoid re-querying the
  // binding map once per user; incremental callers let it load lazily.
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

  // Expand each direct department to itself plus all ancestors, then map the
  // external ids to bound group ids. A Set dedups overlapping ancestor chains.
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
      // Tolerate a membership that already survived (or a concurrent insert)
      // instead of erroring on the composite primary key.
      .onConflictDoNothing()
  }

  return targetGroupIds.size
}

interface IdentityProviderGroupMembershipContext {
  bindingsByExternalId: Map<string, typeof PrincipalGroupExternalBindings.$inferSelect>
  providerGroupIds: string[]
}

/**
 * Loads this provider's department bindings once for membership math.
 *
 * Returns both a by-external-id lookup (used to resolve parents during ancestor
 * expansion) and the flat list of this provider's group ids (used to scope
 * membership deletes). Sharing one read keeps a full sync from re-querying the
 * bindings for every user.
 */
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

/**
 * Disables platform subjects this provider previously managed but that are
 * absent from the current full-sync snapshot.
 *
 * The `identityProviderHasManagedUser` guard is the important part: a
 * platform-subject row created only from a chat observation (no sync evidence)
 * is skipped, so a directory full sync never disables a user the directory has
 * not actually accounted for.
 */
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

/**
 * Deletes provider department bindings absent from the current snapshot.
 *
 * Unlike users, groups have no chat-observation path, so any bound department
 * missing from the snapshot is genuinely gone and can be removed unconditionally.
 */
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

/**
 * Writes (or refreshes) the binding row that ties a provider department to a
 * BullX group.
 *
 * The department's `parentExternalId` is persisted into the binding metadata
 * because `expandGroupAncestors` walks that field to build ancestor membership;
 * the parent link lives here, not on the group row.
 */
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

/**
 * Returns a department's external id followed by its ancestor chain.
 *
 * Walks `parentExternalId` links from the binding metadata. The `visited` set is
 * a cycle guard: a malformed directory that reports a department as its own
 * ancestor (directly or in a loop) would otherwise spin forever here.
 */
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

// Deterministic group name for a provider department. Being a pure function of
// provider + external id is what lets `upsertIdentityProviderGroup` re-adopt a
// group whose binding was lost instead of creating a duplicate.
function externalGroupName(providerId: string, externalId: string): string {
  return `${providerId}:department:${externalId}`.trim().toLowerCase()
}

function requiredText(value: string | null | undefined, field: string): string {
  const normalized = trimOptionalText(value)
  if (!normalized) throw new PrincipalDomainError('invalid_request', `${field} must not be empty`)

  return normalized
}

// A provider id must match the shared external-identity namespace contract, the
// same pattern enforced on the `provider` column, so sync writes can never
// introduce a namespace the rest of the system would reject.
function requiredProviderId(value: string | null | undefined, field: string): string {
  const normalized = requiredText(value, field)
  if (!bullxExternalIdentityNamespaceIdPattern.test(normalized)) {
    throw new PrincipalDomainError('invalid_request', `${field} must match ${bullxExternalIdentityNamespaceIdPattern}`)
  }

  return normalized
}

// Coerces an unknown (possibly non-object or null) JSON value to a safe object so
// metadata merges never spread a primitive.
function metadataObject(value: unknown): JsonObject {
  return jsonObject(value) ?? {}
}

/**
 * Full sync can only disable subjects this provider has previously managed.
 *
 * External Gateway may create the same `platform_subject` row from a message before
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
