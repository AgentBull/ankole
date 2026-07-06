import { describe, expect, test } from 'bun:test'

import { buildDropDatabaseScript } from './app-db'

describe('buildDropDatabaseScript', () => {
  test('terminates active target database sessions before dropping the database', () => {
    const script = buildDropDatabaseScript()

    expect(script).toContain('pg_terminate_backend(pid)')
    expect(script).toContain("WHERE datname = :'dbname'")
    expect(script).toContain('dropdb -U "$POSTGRES_USER" --if-exists "$DB_NAME"')
  })
})
