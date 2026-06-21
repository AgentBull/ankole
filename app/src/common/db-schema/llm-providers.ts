import { sql } from 'drizzle-orm'
import { check, index, jsonb, pgTable, text, timestamp } from 'drizzle-orm/pg-core'
import type { JsonObject } from './principals'

/**
 * Operator-configured LLM provider connections (one row per configured
 * endpoint).
 *
 * `provider_id` is the operator-chosen stable handle referenced elsewhere;
 * `llm_provider` names the underlying vendor/protocol (so several rows can target
 * the same vendor with different base URLs or keys). Rows are managed from the
 * admin console and persist until removed.
 */
export const LlmProviders = pgTable(
  'llm_providers',
  {
    providerId: text('provider_id').primaryKey().notNull(),
    llmProvider: text('llm_provider').notNull(),
    // Optional override; null means the vendor's default endpoint.
    baseUrl: text('base_url'),
    // AEAD-sealed API key (see aead-seal.ts), never the raw secret. Nullable for
    // providers reached without a key (e.g. a local/self-hosted endpoint).
    encryptedApiKey: text('encrypted_api_key'),
    providerOptions: jsonb('provider_options').$type<JsonObject>().default({}).notNull(),
    createdAt: timestamp('created_at', { withTimezone: true })
      .default(sql`now()`)
      .notNull(),
    updatedAt: timestamp('updated_at', { withTimezone: true })
      .default(sql`now()`)
      .notNull()
  },
  t => [
    index('llm_providers_llm_provider_index').on(t.llmProvider),
    // Slug shape keeps provider_id safe to embed in identifiers/paths elsewhere.
    check('llm_providers_provider_id_format', sql`${t.providerId} ~ '^[a-z][a-z0-9_-]{0,62}$'`),
    check('llm_providers_llm_provider_nonempty', sql`${t.llmProvider} <> ''`),
    // `NULL OR <> ''` forbids the empty string while still allowing the column to
    // be genuinely absent — empty-string and "not set" must not be confusable.
    check('llm_providers_base_url_nonempty', sql`${t.baseUrl} IS NULL OR ${t.baseUrl} <> ''`),
    check('llm_providers_encrypted_api_key_nonempty', sql`${t.encryptedApiKey} IS NULL OR ${t.encryptedApiKey} <> ''`),
    check('llm_providers_provider_options_object', sql`jsonb_typeof(${t.providerOptions}) = 'object'`)
  ]
)
