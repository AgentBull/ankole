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
    check('principal_groups_name_lowercase', sql`${t.name} = lower(${t.name})`),
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
    principalUid: text('principal_uid').references(() => Principals.uid, { onDelete: 'cascade' }),
    groupId: uuid('group_id').references(() => PrincipalGroups.id, { onDelete: 'cascade' }),
    resourcePattern: text('resource_pattern').notNull(),
    action: text('action').notNull(),
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
    check(
      'permission_grants_principal_exclusive',
      sql`(${t.principalUid} IS NOT NULL AND ${t.groupId} IS NULL) OR (${t.principalUid} IS NULL AND ${t.groupId} IS NOT NULL)`
    ),
    check('permission_grants_action_no_colon', sql`position(':' in ${t.action}) = 0`),
    check('permission_grants_resource_pattern_present', sql`length(${t.resourcePattern}) > 0`),
    check('permission_grants_action_present', sql`length(${t.action}) > 0`),
    check('permission_grants_metadata_object', sql`jsonb_typeof(${t.metadata}) = 'object'`),
    index('permission_grants_principal_uid_index').on(t.principalUid),
    index('permission_grants_group_id_index').on(t.groupId),
    index('permission_grants_action_index').on(t.action),
    uniqueIndex('permission_grants_principal_upsert_index')
      .on(t.principalUid, t.resourcePattern, t.action, t.condition)
      .where(sql`${t.principalUid} IS NOT NULL`),
    uniqueIndex('permission_grants_group_upsert_index')
      .on(t.groupId, t.resourcePattern, t.action, t.condition)
      .where(sql`${t.groupId} IS NOT NULL`)
  ]
)
