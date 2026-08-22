import { Database } from 'bun:sqlite'
import { existsSync } from 'node:fs'
import { join } from 'node:path'
import { CODEX_HOME_LOCK_BUSY_EXIT_CODE, codexHomeLockedLogsDeleteArgv } from './codex-home-lock'

/** Upstream Codex database affected by the bounded log-growth workaround. */
const LOGS_DATABASE_NAME = 'logs_2.sqlite'
export type CodexLogs2TriggerResult = 'installed' | 'database_missing'

export type CodexLogs2DailyResetResult =
  | { status: 'deleted'; deletedFiles: string[] }
  | { status: 'database_missing'; deletedFiles: [] }
  | { status: 'skipped_runtime_active'; deletedFiles: [] }

/**
 * Reduces Codex diagnostic log growth until the upstream defect is fixed.
 * See https://github.com/openai/codex/issues/27741.
 *
 * This keeps WARNING and higher records. It copies only the low-level filter
 * from https://github.com/yangtzech/codex-logs-trigger-patch/blob/main/patch_codex_logs.sh.
 * It does not stop Codex or change SQLite journal mode.
 */
export function installCodexLogs2LowLevelFilter(codexHome: string): CodexLogs2TriggerResult {
  const databasePath = join(codexHome, LOGS_DATABASE_NAME)
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

/**
 * Deletes only the disposable Codex diagnostic database during daily reset.
 * See https://github.com/openai/codex/issues/27741.
 *
 * This makes one non-blocking attempt to take the same cross-process lock as
 * the Agent app-server. A busy lock means that the runtime is active, so the
 * reset changes nothing.
 */
export async function deleteCodexLogs2AtDailyReset(codexHome: string): Promise<CodexLogs2DailyResetResult> {
  const child = Bun.spawn(codexHomeLockedLogsDeleteArgv(codexHome), {
    cwd: codexHome,
    env: { PATH: process.env.PATH || '/usr/local/bin:/usr/bin:/bin' },
    stdin: 'ignore',
    stdout: 'pipe',
    stderr: 'pipe'
  })
  const [exitCode, stdout, stderr] = await Promise.all([
    child.exited,
    new Response(child.stdout).text(),
    new Response(child.stderr).text()
  ])
  if (exitCode === CODEX_HOME_LOCK_BUSY_EXIT_CODE) {
    return { status: 'skipped_runtime_active', deletedFiles: [] }
  }
  if (exitCode !== 0) throw new Error(`Codex logs reset failed with exit ${exitCode}: ${stderr.trim()}`)

  const deletedFiles = stdout
    .split('\n')
    .map(line => line.trim())
    .filter(Boolean)

  return deletedFiles.length > 0
    ? { status: 'deleted', deletedFiles }
    : { status: 'database_missing', deletedFiles: [] }
}
