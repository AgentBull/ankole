import { Database } from 'bun:sqlite'
import { randomUUID } from 'node:crypto'
import {
  chmodSync,
  closeSync,
  constants,
  fstatSync,
  openSync,
  readSync,
  renameSync,
  unlinkSync,
  writeFileSync
} from 'node:fs'
import { dirname, join } from 'node:path'
import type { Writable } from 'node:stream'
import { AGENT_UID, chownAgentPathSync, mkdirAgentSync } from '../common/agent-user'
import { CLI_CONTEXT_FILE_ENV, CLI_LEDGER_DIR_ENV } from '../core/execution/turn_runtime_env'

const CONTEXT_FILE_NAME = 'context-generation.json'
const CONTEXT_FILE_MAX_BYTES = 4096
const MAX_GUIDANCE_LINES = 12
const MAX_GUIDANCE_CHARS = 1200

export type CliGuidanceDecision = 'pass' | 'attach'

/**
 * Installs a broken-pipe guard on `stdout` so downstream pipes (`| head -n 5`,
 * `| jq`) closing early do not crash the CLI with an unhandled `EPIPE` stack trace.
 */
export function installStdoutEpipeGuard(stream: Writable = process.stdout): void {
  stream.on('error', (error: NodeJS.ErrnoException) => {
    if (error?.code === 'EPIPE' || error?.code === 'ERR_STREAM_DESTROYED') {
      process.exitCode ||= 1
      return
    }
    throw error
  })
}

/**
 * Records that the model explicitly ran `--help` for `commandKey` in the
 * active context epoch so subsequent commands in the same epoch do not emit
 * duplicate first-use guidance on `stderr`.
 */
export function markHelpSeen(opts: { commandKey: string; env?: Record<string, string | undefined> }): void {
  const env = opts.env ?? process.env
  const contextId = readContextGenerationFile(env[CLI_CONTEXT_FILE_ENV])
  const ledgerDir = env[CLI_LEDGER_DIR_ENV]?.trim()
  if (!contextId || !ledgerDir) return

  let db: Database | undefined
  try {
    mkdirAgentSync(ledgerDir, 0o700)
    db = openGuidanceDatabase(join(ledgerDir, 'state.db'))
    if (!probeLedgerWritable(db)) return
    db.query(
      'INSERT OR IGNORE INTO cli_guidance_deliveries (context_id, command_key, delivered_at) VALUES (?, ?, ?)'
    ).run(contextId, opts.commandKey, new Date().toISOString())
  } catch {
    // Best-effort ledger write; `--help` never fails on ledger state.
  } finally {
    try {
      db?.close()
    } catch {
      // Ignore close errors.
    }
  }
}

/**
 * Atomically writes `context-generation.json` inside `dir` so Agent CLI
 * subprocesses (`uid 1000` in container, current user in local tests) observe
 * mid-turn compaction or conversation changes without recreating the workspace.
 */
export function writeContextGenerationFile(dir: string, contextId: string): string {
  const trimmed = contextId.trim()
  if (!trimmed) throw new Error('contextId must be non-empty')
  const targetPath = join(dir, CONTEXT_FILE_NAME)
  const tempPath = join(dir, `.${CONTEXT_FILE_NAME}.${randomUUID()}.tmp`)
  const payload = `${JSON.stringify({
    version: 1,
    contextId: trimmed,
    updatedAt: new Date().toISOString()
  })}\n`

  try {
    writeFileSync(tempPath, payload, { mode: 0o600 })
    chmodSync(tempPath, 0o600)
    chownAgentPathSync(tempPath)
    renameSync(tempPath, targetPath)
    return targetPath
  } catch (error) {
    try {
      unlinkSync(tempPath)
    } catch {
      // Best-effort cleanup of temp file.
    }
    throw error
  }
}

/**
 * Safely reads `context-generation.json` with `O_NOFOLLOW`, regular-file check,
 * `<= 4096` byte cap, and trusted-owner check. Returns `undefined` when missing
 * or untrusted so automation/standalone invocations degrade cleanly to `pass`.
 */
export function readContextGenerationFile(
  filePath: string | undefined = process.env[CLI_CONTEXT_FILE_ENV]
): string | undefined {
  if (!filePath || !filePath.trim()) return undefined
  const flags = constants.O_RDONLY | (constants.O_NOFOLLOW ?? 0)
  let fd: number | undefined
  try {
    fd = openSync(filePath, flags)
    const stat = fstatSync(fd)
    if (!stat.isFile() || stat.size <= 0 || stat.size > CONTEXT_FILE_MAX_BYTES) return undefined
    const currentUid = process.getuid?.()
    if (currentUid !== undefined && stat.uid !== currentUid && stat.uid !== 0 && stat.uid !== AGENT_UID) {
      return undefined
    }
    const buffer = Buffer.alloc(stat.size)
    const bytesRead = readSync(fd, buffer, 0, stat.size, 0)
    const parsed: unknown = JSON.parse(buffer.subarray(0, bytesRead).toString('utf8'))
    if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) return undefined
    const record = parsed as Record<string, unknown>
    if (record.version !== 1 || typeof record.contextId !== 'string') return undefined
    const contextId = record.contextId.trim()
    return contextId.length > 0 && contextId.length <= 512 ? contextId : undefined
  } catch {
    return undefined
  } finally {
    if (fd !== undefined) {
      try {
        closeSync(fd)
      } catch {
        // Ignore close errors.
      }
    }
  }
}

/**
 * Emits a concise (`<= 12` lines, `<= 1,200` chars) first-use usage note to
 * `stderr` at most once per `(contextId, commandKey)` while keeping `stdout`
 * pure JSON for machine consumers (`JSON.parse`, `jq`, pipelines).
 */
export async function emitFirstUseGuidance(opts: {
  commandKey: string
  guidance: string
  stderr?: Writable
  env?: Record<string, string | undefined>
}): Promise<CliGuidanceDecision> {
  const env = opts.env ?? process.env
  const stderr = opts.stderr ?? process.stderr
  const normalizedGuidance = boundGuidance(opts.guidance)
  if (!normalizedGuidance) return 'pass'

  const contextId = readContextGenerationFile(env[CLI_CONTEXT_FILE_ENV])
  if (!contextId) return 'pass'

  const ledgerDir = env[CLI_LEDGER_DIR_ENV]?.trim()
  let db: Database | undefined
  let ledgerWritable = false

  if (ledgerDir) {
    try {
      mkdirAgentSync(ledgerDir, 0o700)
      db = openGuidanceDatabase(join(ledgerDir, 'state.db'))
      const existing = db
        .query('SELECT 1 FROM cli_guidance_deliveries WHERE context_id = ? AND command_key = ? LIMIT 1')
        .get(contextId, opts.commandKey)
      if (existing) {
        db.close()
        return 'pass'
      }
      ledgerWritable = probeLedgerWritable(db)
    } catch {
      try {
        db?.close()
      } catch {
        // Ignore close errors on degraded ledger.
      }
      db = undefined
      ledgerWritable = false
    }
  }

  const formatted = `[ankole-cli first-use note: ${opts.commandKey}]\n${normalizedGuidance}\n`

  try {
    await writeStderrChunk(stderr, formatted)
    if (db && ledgerWritable) {
      try {
        db.query(
          'INSERT OR IGNORE INTO cli_guidance_deliveries (context_id, command_key, delivered_at) VALUES (?, ?, ?)'
        ).run(contextId, opts.commandKey, new Date().toISOString())
      } catch {
        // Degrade gracefully without failing the CLI command.
      }
    }
    return 'attach'
  } catch {
    return 'pass'
  } finally {
    try {
      db?.close()
    } catch {
      // Ignore close errors.
    }
  }
}

function openGuidanceDatabase(dbPath: string): Database {
  mkdirAgentSync(dirname(dbPath), 0o700)
  const db = new Database(dbPath, { create: true })
  db.exec('PRAGMA busy_timeout = 3000;')
  db.exec('PRAGMA journal_mode = WAL;')
  db.exec(`
    CREATE TABLE IF NOT EXISTS cli_guidance_deliveries (
      context_id TEXT NOT NULL,
      command_key TEXT NOT NULL,
      delivered_at TEXT NOT NULL,
      PRIMARY KEY (context_id, command_key)
    );
  `)
  try {
    chownAgentPathSync(dbPath)
  } catch {
    // Ignore chown errors on non-root filesystems.
  }
  return db
}

function probeLedgerWritable(db: Database): boolean {
  try {
    db.exec('BEGIN IMMEDIATE; ROLLBACK;')
    return true
  } catch {
    return false
  }
}

function boundGuidance(raw: string): string {
  const lines = raw.trim().split('\n').slice(0, MAX_GUIDANCE_LINES)
  const joined = lines.join('\n')
  return joined.length <= MAX_GUIDANCE_CHARS ? joined : joined.slice(0, MAX_GUIDANCE_CHARS)
}

function writeStderrChunk(stream: Writable, text: string): Promise<void> {
  return new Promise((resolve, reject) => {
    stream.write(text, error => {
      if (error) reject(error)
      else resolve()
    })
  })
}
