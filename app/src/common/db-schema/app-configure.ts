import { sql } from 'drizzle-orm'
import type { JsonValue } from './principals'
import { check, jsonb, pgTable, text, timestamp, unique } from 'drizzle-orm/pg-core'

export enum ConfigureKeyType {
  PLAINTEXT = 'plaintext',
  CIPHER = 'cipher'
}

export type ConfigureJsonValue = JsonValue

export interface ConfigureValue {
  type: ConfigureKeyType
  value: ConfigureJsonValue
  [key: string]: ConfigureJsonValue
}

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
    check(
      'app_configure_value_envelope',
      sql`jsonb_typeof(${t.value}) = 'object' AND ${t.value} ? 'type' AND ${t.value} ? 'value'`
    )
  ]
)
