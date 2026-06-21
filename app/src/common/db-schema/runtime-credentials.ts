import { sql } from 'drizzle-orm'
import { boolean, check, index, jsonb, pgTable, text, timestamp, uniqueIndex, uuid } from 'drizzle-orm/pg-core'
import { Agents, type JsonObject } from './principals'

/**
 * Encrypted credential blobs consumed by skills, tools, or runtime integrations.
 *
 * The table is intentionally generic: Codex auth, GitHub tokens, PDF tool API keys,
 * and future skill-owned credentials all share the same default/agent override
 * model. Runtime files materialized from these rows are disposable and must not be
 * synced back through TigerFS.
 */
export const RuntimeCredentials = pgTable(
  'runtime_credentials',
  {
    id: uuid('id').primaryKey().notNull(),
    // Addressing tuple: which kind of thing consumes this (skill/tool/runtime),
    // its name, and the named credential it asks for. Lookups are by this tuple,
    // not by id.
    consumerKind: text('consumer_kind').notNull(),
    consumerName: text('consumer_name').notNull(),
    credentialName: text('credential_name').notNull(),
    // `default` = installation-wide fallback (agent_uid null); `agent` = override
    // for one agent. Resolution prefers the agent row and falls back to default.
    scopeKind: text('scope_kind').notNull(),
    agentUid: text('agent_uid').references(() => Agents.uid, { onDelete: 'cascade' }),
    // AEAD-sealed credential bytes (see aead-seal.ts), never the raw secret.
    encryptedPayload: text('encrypted_payload').notNull(),
    payloadMediaType: text('payload_media_type').default('text/plain').notNull(),
    // BLAKE3 of the plaintext payload, used to detect changes / dedupe rotations
    // without unsealing the ciphertext.
    payloadBlake3: text('payload_blake3').notNull(),
    metadata: jsonb('metadata').$type<JsonObject>().default({}).notNull(),
    enabled: boolean('enabled').default(true).notNull(),
    createdAt: timestamp('created_at', { withTimezone: true })
      .default(sql`now()`)
      .notNull(),
    updatedAt: timestamp('updated_at', { withTimezone: true })
      .default(sql`now()`)
      .notNull()
  },
  t => [
    // At most one default per credential tuple...
    uniqueIndex('runtime_credentials_default_index')
      .on(t.consumerKind, t.consumerName, t.credentialName)
      .where(sql`${t.scopeKind} = 'default'`),
    // ...and at most one override per (credential tuple, agent). Splitting into
    // two partial indexes lets agent_uid be null for defaults while still keeping
    // each scope unique on its own key.
    uniqueIndex('runtime_credentials_agent_index')
      .on(t.consumerKind, t.consumerName, t.credentialName, t.agentUid)
      .where(sql`${t.scopeKind} = 'agent'`),
    // Serves the resolve path: filter by credential tuple + scope, skipping
    // disabled rows, then pick agent-over-default.
    index('runtime_credentials_lookup_index').on(
      t.consumerKind,
      t.consumerName,
      t.credentialName,
      t.scopeKind,
      t.enabled
    ),
    check('runtime_credentials_consumer_kind_check', sql`${t.consumerKind} in ('skill', 'tool', 'runtime')`),
    check('runtime_credentials_scope_kind_check', sql`${t.scopeKind} in ('default', 'agent')`),
    // Ties scope_kind to the presence of agent_uid: a default must not name an
    // agent, an agent override must. Stops a row whose scope and target disagree.
    check(
      'runtime_credentials_scope_agent_shape',
      sql`(${t.scopeKind} = 'default' AND ${t.agentUid} IS NULL) OR (${t.scopeKind} = 'agent' AND ${t.agentUid} IS NOT NULL)`
    ),
    check('runtime_credentials_consumer_name_format', sql`${t.consumerName} ~ '^[a-z][a-z0-9_-]{0,63}$'`),
    check('runtime_credentials_name_format', sql`${t.credentialName} ~ '^[a-z][a-z0-9_-]{0,63}$'`),
    check('runtime_credentials_payload_nonempty', sql`length(${t.encryptedPayload}) > 0`),
    check('runtime_credentials_payload_media_type_nonempty', sql`length(trim(${t.payloadMediaType})) > 0`),
    check('runtime_credentials_metadata_object', sql`jsonb_typeof(${t.metadata}) = 'object'`)
  ]
)
