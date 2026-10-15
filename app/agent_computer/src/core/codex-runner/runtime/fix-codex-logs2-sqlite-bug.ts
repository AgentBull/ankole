import { Database } from 'bun:sqlite'
import { existsSync } from 'node:fs'
import { join } from 'node:path'

const LOGS_DATABASE_NAME = 'logs_2.sqlite'
export type CodexLogs2TriggerResult = 'installed' | 'database_missing'

export function installCodexLogs2LowLevelFilter(sqliteHome: string): CodexLogs2TriggerResult {
  const databasePath = join(sqliteHome, LOGS_DATABASE_NAME)
  if (!existsSync(databasePath)) return 'database_missing'

  const database = new Database(databasePath, { create: false, strict: true })
  try {
    database.run('PRAGMA busy_timeout = 5000')
    database.run(`
      CREATE TRIGGER IF NOT EXISTS drop_low_level_logs
      BEFORE INSERT ON logs
      FOR EACH ROW
      WHEN NEW.level IN ('TRACE', 'DEBUG', 'INFO')
      BEGIN
        SELECT RAISE(IGNORE);
      END
    `)
    return 'installed'
  } finally {
    database.close()
  }
}
