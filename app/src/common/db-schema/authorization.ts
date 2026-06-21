import { sql } from 'drizzle-orm'
import {
  boolean,
  check,
  index,
  jsonb,
  pgEnum,
  pgTable,
  primaryKey,
  text,
  timestamp,
  uniqueIndex,
  uuid
} from 'drizzle-orm/pg-core'
import { type JsonObject, Principals } from './principals'

/**
 * Static groups have explicit memberships. Computed groups are evaluated by the
 * native AuthZ engine from a CEL condition against the Principal snapshot.
 */
export const PrincipalGroupKind = pgEnum('principal_group_kind', ['static', 'computed'])

/**
 * Authorization group definition.
 *
 * Built-ins are rows, not hard-coded branches in the query layer, so they can
 * own grants the same way operator-created groups do. Computed groups store the
 * CEL condition that decides membership at authorization time.
 */
export const PrincipalGroups = pgTable(
  'principal_groups',
  {
    id: uuid('id').primaryKey().notNull(),
    name: text('name').notNull(),
    kind: PrincipalGroupKind('kind').default('static').notNull(),
    description: text('description'),
    computedCondition: text('computed_condition'),
    builtIn: boolean('built_in').default(false).notNull(),
    createdAt: timestamp('created_at')
      .default(sql`CURRENT_TIMESTAMP`)
      .notNull(),
    updatedAt: timestamp('updated_at')
      .default(sql`CURRENT_TIMESTAMP`)
      .notNull()
  },
  t => [
    uniqueIndex('principal_groups_name_index').on(t.name),
    check('principal_groups_name_present', sql`length(btrim(${t.name})) > 0`),
    // Names are lowercase so the unique index above is also case-insensitive in
    // practice; callers can compare group names as plain text.
    check('principal_groups_name_lowercase', sql`${t.name} = lower(${t.name})`),
    // Ties kind to the condition column: static groups must have no CEL condition,
    // computed groups must have a non-blank one. Prevents a static group that
    // silently carries a stale condition, or a computed group with nothing to
    // evaluate.
    check(
      'principal_groups_computed_condition_by_kind',
      sql`(${t.kind} = 'static' AND ${t.computedCondition} IS NULL) OR (${t.kind} = 'computed' AND length(btrim(${t.computedCondition})) > 0)`
    )
  ]
)

/**
 * Explicit membership edge for static groups.
 *
 * Computed group membership is never stored here; the native engine derives it
 * from `principal_groups.computed_condition` for each authorization snapshot.
 */
export const PrincipalGroupMemberships = pgTable(
  'principal_group_memberships',
  {
    principalUid: text('principal_uid')
      .notNull()
      .references(() => Principals.uid, { onDelete: 'cascade' }),
    groupId: uuid('group_id')
      .notNull()
      .references(() => PrincipalGroups.id, { onDelete: 'cascade' }),
    createdAt: timestamp('created_at')
      .default(sql`CURRENT_TIMESTAMP`)
      .notNull(),
    updatedAt: timestamp('updated_at')
      .default(sql`CURRENT_TIMESTAMP`)
      .notNull()
  },
  t => [
    primaryKey({ columns: [t.principalUid, t.groupId] }),
    index('principal_group_memberships_group_id_index').on(t.groupId)
  ]
)

/**
 * External directory binding for static Principal groups.
 *
 * Identity-provider sync owns these rows so a provider department can be
 * renamed without losing grants attached to the BullX group row.
 */
export const PrincipalGroupExternalBindings = pgTable(
  'principal_group_external_bindings',
  {
    provider: text('provider').notNull(),
    externalId: text('external_id').notNull(),
    groupId: uuid('group_id')
      .notNull()
      .references(() => PrincipalGroups.id, { onDelete: 'cascade' }),
    metadata: jsonb('metadata').$type<JsonObject>().default({}).notNull(),
    createdAt: timestamp('created_at')
      .default(sql`CURRENT_TIMESTAMP`)
      .notNull(),
    updatedAt: timestamp('updated_at')
      .default(sql`CURRENT_TIMESTAMP`)
      .notNull()
  },
  t => [
    // Keyed by the external (provider, external_id), so the directory side owns
    // the row identity; the BullX group_id can move without breaking the binding.
    primaryKey({ columns: [t.provider, t.externalId] }),
    // Reverse lookup: which external bindings feed a given group.
    index('principal_group_external_bindings_group_id_index').on(t.groupId),
    check('principal_group_external_bindings_provider_present', sql`length(btrim(${t.provider})) > 0`),
    check('principal_group_external_bindings_provider_format', sql`${t.provider} ~ '^[a-z][a-z0-9_-]*$'`),
    check('principal_group_external_bindings_external_id_present', sql`length(btrim(${t.externalId})) > 0`),
    check('principal_group_external_bindings_metadata_object', sql`jsonb_typeof(${t.metadata}) = 'object'`)
  ]
)

/**
 * Permission grant owned by exactly one Principal or one group.
 *
 * `resource_pattern` uses the AuthZ resource glob syntax, `action` is an exact
 * action key, and `condition` is a CEL boolean expression evaluated after the
 * owner/resource/action checks have matched.
 */
export const PermissionGrants = pgTable(
  'permission_grants',
  {
    id: uuid('id').primaryKey().notNull(),
    // Owner is exactly one of principal_uid / group_id (enforced by the
    // principal_exclusive check). A group grant fans out to all current members
    // at evaluation time without duplicating the grant per member.
    principalUid: text('principal_uid').references(() => Principals.uid, { onDelete: 'cascade' }),
    groupId: uuid('group_id').references(() => PrincipalGroups.id, { onDelete: 'cascade' }),
    resourcePattern: text('resource_pattern').notNull(),
    action: text('action').notNull(),
    // CEL boolean evaluated only after owner/resource/action already matched;
    // defaults to the literal 'true' so an unconditional grant is still a normal,
    // non-null condition rather than a special case.
    condition: text('condition').default('true').notNull(),
    description: text('description'),
    metadata: jsonb('metadata').$type<JsonObject>().default({}).notNull(),
    createdAt: timestamp('created_at')
      .default(sql`CURRENT_TIMESTAMP`)
      .notNull(),
    updatedAt: timestamp('updated_at')
      .default(sql`CURRENT_TIMESTAMP`)
      .notNull()
  },
  t => [
    // Exactly-one-owner invariant: never both, never neither.
    check(
      'permission_grants_principal_exclusive',
      sql`(${t.principalUid} IS NOT NULL AND ${t.groupId} IS NULL) OR (${t.principalUid} IS NULL AND ${t.groupId} IS NOT NULL)`
    ),
    // `:` is reserved as the resource/action separator in the AuthZ key syntax, so
    // it must not appear inside a bare action token.
    check('permission_grants_action_no_colon', sql`position(':' in ${t.action}) = 0`),
    check('permission_grants_resource_pattern_present', sql`length(${t.resourcePattern}) > 0`),
    check('permission_grants_action_present', sql`length(${t.action}) > 0`),
    check('permission_grants_metadata_object', sql`jsonb_typeof(${t.metadata}) = 'object'`),
    index('permission_grants_principal_uid_index').on(t.principalUid),
    index('permission_grants_group_id_index').on(t.groupId),
    // Supports "who can do this action" sweeps independent of owner.
    index('permission_grants_action_index').on(t.action),
    // Idempotent upsert keys: a grant is identified by (owner, resource, action,
    // condition), so re-granting the same tuple updates in place instead of
    // piling up duplicates. Two partial indexes because the owner column differs
    // per branch and only one is non-null at a time.
    uniqueIndex('permission_grants_principal_upsert_index')
      .on(t.principalUid, t.resourcePattern, t.action, t.condition)
      .where(sql`${t.principalUid} IS NOT NULL`),
    uniqueIndex('permission_grants_group_upsert_index')
      .on(t.groupId, t.resourcePattern, t.action, t.condition)
      .where(sql`${t.groupId} IS NOT NULL`)
  ]
)
