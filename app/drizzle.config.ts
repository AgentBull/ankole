import { defineConfig } from 'drizzle-kit'

export default defineConfig({
  schema: './src/common/db-schema/index.ts',
  out: './db',
  dialect: 'postgresql',
  dbCredentials: {
    url: process.env.DATABASE_URL!
  },
  migrations: {
    prefix: 'timestamp',
    schema: 'public',
    table: 'schema_migrations'
  },
  strict: true
})
