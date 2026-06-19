import { sql } from 'drizzle-orm'
import { check, index, jsonb, pgTable, text, timestamp } from 'drizzle-orm/pg-core'
import type { JsonObject } from './principals'

export const LlmProviders = pgTable(
  'llm_providers',
  {
    providerId: text('provider_id').primaryKey().notNull(),
    llmProvider: text('llm_provider').notNull(),
    baseUrl: text('base_url'),
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
    check('llm_providers_provider_id_format', sql`${t.providerId} ~ '^[a-z][a-z0-9_-]{0,62}$'`),
    check('llm_providers_llm_provider_nonempty', sql`${t.llmProvider} <> ''`),
    check('llm_providers_base_url_nonempty', sql`${t.baseUrl} IS NULL OR ${t.baseUrl} <> ''`),
    check('llm_providers_encrypted_api_key_nonempty', sql`${t.encryptedApiKey} IS NULL OR ${t.encryptedApiKey} <> ''`),
    check('llm_providers_provider_options_object', sql`jsonb_typeof(${t.providerOptions}) = 'object'`)
  ]
)
