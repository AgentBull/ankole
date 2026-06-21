import { sql } from 'drizzle-orm'
import type { JsonValue } from './principals'
import { check, jsonb, pgTable, text, timestamp, unique } from 'drizzle-orm/pg-core'

/**
 * Marks whether a config value's `value` field holds the literal setting
 * (`plaintext`) or an AEAD-sealed blob (`cipher`) that must be unsealed before
 * use. The tag travels with the row so a reader knows how to interpret `value`
 * without consulting a separate schema of which keys are secret.
 */
export enum ConfigureKeyType {
  PLAINTEXT = 'plaintext',
  CIPHER = 'cipher'
}

export type ConfigureJsonValue = JsonValue

/**
 * Self-describing config envelope stored in `app_configure.value`.
 *
 * `type` says how to read `value`; the open index signature allows extra
 * sidecar fields (e.g. cipher metadata) without a schema change. The DB check
 * constraint enforces that every stored object actually carries `type` and
 * `value`, so a malformed write fails at insert time rather than at read.
 */
export interface ConfigureValue {
  type: ConfigureKeyType
  value: ConfigureJsonValue
  [key: string]: ConfigureJsonValue
}

/**
 * Installation-wide key/value settings store (one row per `key`).
 *
 * General-purpose config table for the single BullX installation; rows are
 * upserted by operators/setup and live for the lifetime of the installation.
 * Secrets and plaintext settings share one table, distinguished by the
 * {@link ConfigureValue} envelope rather than by separate tables.
 */
export const AppConfigure = pgTable(
  'app_configure',
  {
    key: text('key').notNull(),
    value: jsonb('value').$type<ConfigureValue>().notNull(),
    createdAt: timestamp('created_at')
      .default(sql`CURRENT_TIMESTAMP`)
      .notNull(),
    updatedAt: timestamp('updated_at')
      .default(sql`CURRENT_TIMESTAMP`)
      .notNull()
  },
  t => [
    unique('key_unique').on(t.key),
    // Guards the envelope invariant: every value must be a JSON object carrying
    // both `type` and `value` (the `?` operator is jsonb key-existence). Keeps a
    // half-formed or bare-scalar write from ever landing as config.
    check(
      'app_configure_value_envelope',
      sql`jsonb_typeof(${t.value}) = 'object' AND ${t.value} ? 'type' AND ${t.value} ? 'value'`
    )
  ]
)
