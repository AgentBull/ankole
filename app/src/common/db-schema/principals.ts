import { sql } from 'drizzle-orm'
import { check, index, jsonb, pgEnum, pgTable, text, timestamp, unique, uniqueIndex, uuid } from 'drizzle-orm/pg-core'

export type JsonValue = string | number | boolean | null | { [key: string]: JsonValue } | JsonValue[]

export type JsonObject = { [key: string]: JsonValue }

/**
 * Principal is the stable authorization subject in BullX Agent.
 *
 * `human` and `agent` share the same top-level lifecycle/status fields so
 * authorization can evaluate a subject without first knowing its subtype table.
 */
export const PrincipalType = pgEnum('principal_type', ['human', 'agent'])
export const PrincipalStatus = pgEnum('principal_status', ['active', 'disabled'])

/**
 * Agent runtime shape. V1 only persists the LLM agentic loop type, but keeping
 * this as a PostgreSQL enum makes future agent runtimes an explicit schema
 * migration instead of an untracked string convention.
 */
export const AgentType = pgEnum('agent_type', ['llm_agentic_loop'])

/**
 * External identities are not all login identities. A channel actor identifies
 * inbound IM/message actors, login_subject is reserved for future web/OIDC
 * login matching, and outbound_actor is for provider-side send-as identity.
 */
export const PrincipalExternalIdentityKind = pgEnum('principal_external_identity_kind', [
  'channel_actor',
  'login_subject',
  'outbound_actor'
])

/**
 * Top-level subject table.
 *
 * `uid` is the business-facing subject key used by the rest of Principal/AuthZ.
 * It is lowercase and unique so callers can use stable text identifiers without
 * leaking internal UUID primary keys into permission grants or memberships.
 */
export const Principals = pgTable(
  'principals',
  {
    id: uuid('id').primaryKey().notNull(),
    uid: text('uid').notNull(),
    type: PrincipalType('type').notNull(),
    status: PrincipalStatus('status').default('active').notNull(),
    displayName: text('display_name'),
    avatarUrl: text('avatar_url'),
    createdAt: timestamp('created_at')
      .default(sql`CURRENT_TIMESTAMP`)
      .notNull(),
    updatedAt: timestamp('updated_at')
      .default(sql`CURRENT_TIMESTAMP`)
      .notNull()
  },
  t => [unique('principals_uid_unique').on(t.uid), check('principals_uid_lowercase', sql`${t.uid} = lower(${t.uid})`)]
)

/**
 * Human-specific profile row keyed by `principals.uid`.
 *
 * Email and phone are optional because a human can enter the system through an
 * IM channel before web login exists. When present they are unique identifiers.
 */
export const HumanUsers = pgTable(
  'human_users',
  {
    principalUid: text('principal_uid')
      .primaryKey()
      .notNull()
      .references(() => Principals.uid, { onDelete: 'cascade' }),
    email: text('email'),
    phone: text('phone'),
    createdAt: timestamp('created_at')
      .default(sql`CURRENT_TIMESTAMP`)
      .notNull(),
    updatedAt: timestamp('updated_at')
      .default(sql`CURRENT_TIMESTAMP`)
      .notNull()
  },
  t => [
    uniqueIndex('human_users_email_index')
      .on(t.email)
      .where(sql`${t.email} IS NOT NULL`),
    uniqueIndex('human_users_phone_index')
      .on(t.phone)
      .where(sql`${t.phone} IS NOT NULL`)
  ]
)

/**
 * Agent-specific profile row keyed by `principals.uid`.
 *
 * `metadata` is intentionally an object, not an array or scalar, so future
 * agent-specific knobs can be added without changing the public create/update
 * contract. `profile` is not part of this schema.
 */
export const Agents = pgTable(
  'agents',
  {
    uid: text('uid')
      .primaryKey()
      .notNull()
      .references(() => Principals.uid, { onDelete: 'cascade' }),
    type: AgentType('type').default('llm_agentic_loop').notNull(),
    metadata: jsonb('metadata').$type<JsonObject>().default({}).notNull(),
    createdByPrincipalUid: text('created_by_principal_uid').references(() => Principals.uid, { onDelete: 'set null' }),
    createdAt: timestamp('created_at')
      .default(sql`CURRENT_TIMESTAMP`)
      .notNull(),
    updatedAt: timestamp('updated_at')
      .default(sql`CURRENT_TIMESTAMP`)
      .notNull()
  },
  t => [
    index('agents_created_by_principal_uid_index').on(t.createdByPrincipalUid),
    check('agents_metadata_object', sql`jsonb_typeof(${t.metadata}) = 'object'`)
  ]
)

/**
 * Provider identity binding for a Principal.
 *
 * V1 uses `channel_actor` resolution for inbound actor lookup. `login_subject`
 * and `outbound_actor` are persisted now so the identity model does not need a
 * second migration when those flows are wired later.
 */
export const PrincipalExternalIdentities = pgTable(
  'principal_external_identities',
  {
    id: uuid('id').primaryKey().notNull(),
    principalUid: text('principal_uid')
      .notNull()
      .references(() => Principals.uid, { onDelete: 'cascade' }),
    kind: PrincipalExternalIdentityKind('kind').notNull(),
    provider: text('provider'),
    adapter: text('adapter'),
    channelId: text('channel_id'),
    externalId: text('external_id'),
    verifiedAt: timestamp('verified_at'),
    metadata: jsonb('metadata').$type<JsonObject>().default({}).notNull(),
    createdAt: timestamp('created_at')
      .default(sql`CURRENT_TIMESTAMP`)
      .notNull(),
    updatedAt: timestamp('updated_at')
      .default(sql`CURRENT_TIMESTAMP`)
      .notNull()
  },
  t => [
    index('principal_external_identities_principal_uid_index').on(t.principalUid),
    uniqueIndex('principal_external_identities_channel_actor_index')
      .on(t.adapter, t.channelId, t.externalId)
      .where(sql`${t.kind} = 'channel_actor'`),
    uniqueIndex('principal_external_identities_login_subject_index')
      .on(t.provider, t.externalId)
      .where(sql`${t.kind} = 'login_subject'`),
    uniqueIndex('principal_external_identities_outbound_actor_index')
      .on(t.provider, t.externalId)
      .where(sql`${t.kind} = 'outbound_actor'`),
    check(
      'principal_external_identities_channel_actor_required',
      sql`(${t.kind} <> 'channel_actor') OR (${t.adapter} IS NOT NULL AND ${t.channelId} IS NOT NULL AND ${t.externalId} IS NOT NULL)`
    ),
    check(
      'principal_external_identities_provider_subject_required',
      sql`(${t.kind} NOT IN ('login_subject', 'outbound_actor')) OR (${t.provider} IS NOT NULL AND ${t.externalId} IS NOT NULL)`
    ),
    check('principal_external_identities_metadata_object', sql`jsonb_typeof(${t.metadata}) = 'object'`)
  ]
)
