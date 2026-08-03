import { Database } from 'bun:sqlite'
import { existsSync, readFileSync, readdirSync, unlinkSync } from 'node:fs'
import { basename, join } from 'node:path'

const LOGS_DATABASE_NAME = 'logs_2.sqlite'
const LOGS_DATABASE_FILES = [
  LOGS_DATABASE_NAME,
  `${LOGS_DATABASE_NAME}-wal`,
  `${LOGS_DATABASE_NAME}-shm`,
  `${LOGS_DATABASE_NAME}-journal`
] as const

export type CodexLogs2TriggerResult = 'installed' | 'database_missing'

export type CodexLogs2DailyResetResult =
  | { status: 'deleted'; deletedFiles: string[] }
  | { status: 'database_missing'; deletedFiles: [] }
  | { status: 'skipped_codex_running'; deletedFiles: []; activeCodexProcesses: number }

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
 * The caller must hold the matching Codex Home setup fence. If any Codex
 * process is still present in this Worker container, this function changes
 * nothing and lets the next daily reset try again.
 */
export function deleteCodexLogs2AtDailyReset(codexHome: string): CodexLogs2DailyResetResult {
  const activeCodexProcesses = countActiveCodexProcesses()
  if (activeCodexProcesses > 0) {
    return { status: 'skipped_codex_running', deletedFiles: [], activeCodexProcesses }
  }

  const deletedFiles: string[] = []
  for (const name of LOGS_DATABASE_FILES) {
    const path = join(codexHome, name)
    if (!existsSync(path)) continue
    unlinkSync(path)
    deletedFiles.push(name)
  }

  return deletedFiles.length > 0
    ? { status: 'deleted', deletedFiles }
    : { status: 'database_missing', deletedFiles: [] }
}

function countActiveCodexProcesses(): number {
  let count = 0
  for (const entry of readdirSync('/proc', { withFileTypes: true })) {
    if (!entry.isDirectory() || !/^\d+$/.test(entry.name)) continue

    const processName = readProcessFile(entry.name, 'comm').trim()
    const argv = readProcessFile(entry.name, 'cmdline').split('\0').filter(Boolean)
    const executableName = basename(argv[0] ?? '')
    if (isCodexProcessName(processName) || isCodexProcessName(executableName)) count += 1
  }
  return count
}

function readProcessFile(pid: string, name: 'comm' | 'cmdline'): string {
  try {
    return readFileSync(join('/proc', pid, name), 'utf8')
  } catch {
    // The process can exit between the directory scan and this read.
    return ''
  }
}

function isCodexProcessName(name: string): boolean {
  return name === 'codex' || name.startsWith('codex-')
}
