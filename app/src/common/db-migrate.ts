import { migrate } from 'drizzle-orm/bun-sql/migrator'
import { closeDatabase, DB } from './database'

/**
 * Applies generated Drizzle migrations through the same Bun SQL driver used by
 * the app runtime.
 *
 * `drizzle-kit generate` is still the schema-diff generator and keeps
 * `app/db/*.sql` plus `app/db/meta/*` as the migration source of truth.
 * `drizzle-kit migrate` is not used here because it requires a separate Node
 * PostgreSQL driver stack, while this project intentionally standardizes local
 * database execution on Bun SQL.
 */
await migrate(DB, {
  migrationsFolder: './db',
  migrationsSchema: 'public',
  migrationsTable: 'schema_migrations'
})

// oxlint-disable-next-line no-console
console.log('Database migrated successfully.')

// One-shot script: migrations are done, so close fast and exit. The 1s timeout
// just bounds the wait — there is no live traffic to drain here.
await closeDatabase({ timeout: 1 })
