import { join } from 'node:path'

/** Exit code that reports a live lock owner without changing Codex Home. */
export const CODEX_HOME_LOCK_BUSY_EXIT_CODE = 75
/** Cross-process lock held for the lifetime of one Agent app-server. */
export const CODEX_HOME_RUNTIME_LOCK_NAME = '.ankole-app-server.lock'
/** Bootstrap config passed only to the lock-owning startup wrapper. */
export const CODEX_RUNTIME_CONFIG_TOML_ENV = 'ANKOLE_CODEX_RUNTIME_CONFIG_TOML'
/** Bootstrap token passed only to the lock-owning startup wrapper. */
export const CODEX_RUNTIME_TOKEN_ENV = 'ANKOLE_CODEX_RUNTIME_TOKEN'
/** Disposable Codex log database files removed only while the lock is free. */
export const CODEX_LOGS2_DATABASE_NAMES = [
  'logs_2.sqlite',
  'logs_2.sqlite-wal',
  'logs_2.sqlite-shm',
  'logs_2.sqlite-journal'
] as const

export function codexHomeRuntimeLockPath(codexHome: string): string {
  return join(codexHome, CODEX_HOME_RUNTIME_LOCK_NAME)
}

/**
 * Serializes all cross-process changes to one Codex Home.
 * The app-server holds the lock for its lifetime. Maintenance exits with code
 * 75 when another process owns the lock and leaves live files unchanged.
 */
export function codexHomeLockedCommandArgv(input: {
  codexHome: string
  commandArgv: string[]
  deleteLogsBeforeCommand?: boolean
  runtimeFiles?: {
    configPath: string
    tokenPath: string
  }
}): string[] {
  const lockPath = codexHomeRuntimeLockPath(input.codexHome)
  const lockArgv = [flockCommand(), '-n', '-E', String(CODEX_HOME_LOCK_BUSY_EXIT_CODE), '-F', lockPath]
  if (!input.deleteLogsBeforeCommand && !input.runtimeFiles) {
    return [...lockArgv, ...input.commandArgv]
  }

  const databasePaths = CODEX_LOGS2_DATABASE_NAMES.map(name => join(input.codexHome, name))
  const runtimePaths = input.runtimeFiles ? [input.runtimeFiles.configPath, input.runtimeFiles.tokenPath] : []
  return [
    ...lockArgv,
    '/bin/sh',
    '-c',
    lockedRuntimeScript(Boolean(input.runtimeFiles), input.deleteLogsBeforeCommand === true),
    'ankole-codex-runtime',
    ...runtimePaths,
    ...databasePaths,
    ...input.commandArgv
  ]
}

export function codexHomeLockedLogsDeleteArgv(codexHome: string): string[] {
  const databasePaths = CODEX_LOGS2_DATABASE_NAMES.map(name => join(codexHome, name))
  return [
    flockCommand(),
    '-n',
    '-E',
    String(CODEX_HOME_LOCK_BUSY_EXIT_CODE),
    '-F',
    codexHomeRuntimeLockPath(codexHome),
    '/bin/sh',
    '-c',
    'for path do if [ -e "$path" ]; then basename "$path"; rm -f -- "$path"; fi; done',
    'ankole-codex-logs2-reset',
    ...databasePaths
  ]
}

export function legacySharedCodexConfigDeleteArgv(agentHome: string): string[] {
  const legacyCodexHome = join(agentHome, '.codex')
  return [
    flockCommand(),
    '-n',
    '-E',
    String(CODEX_HOME_LOCK_BUSY_EXIT_CODE),
    '-F',
    codexHomeRuntimeLockPath(legacyCodexHome),
    '/bin/sh',
    '-c',
    'legacy_home=$1; find -P "$legacy_home" -mindepth 1 -maxdepth 1 -name config.toml ! -type d -print -delete',
    'ankole-legacy-codex-config-retirement',
    legacyCodexHome
  ]
}

// Write config and token after lock acquisition. Remove both values from the
// environment before exec starts Codex.
function lockedRuntimeScript(writeRuntimeFiles: boolean, deleteLogs: boolean): string {
  const statements = ['set -eu', 'umask 077']

  if (writeRuntimeFiles) {
    statements.push(
      'config_path=$1; token_path=$2; shift 2',
      'config_tmp="${config_path}.tmp-$$"; token_tmp="${token_path}.tmp-$$"',
      'trap \'rm -f -- "$config_tmp" "$token_tmp"\' 0 1 2 15',
      `printf '%s' "$${CODEX_RUNTIME_CONFIG_TOML_ENV}" > "$config_tmp"`,
      `printf '%s' "$${CODEX_RUNTIME_TOKEN_ENV}" > "$token_tmp"`,
      'chmod 600 "$config_tmp" "$token_tmp"',
      'mv -f -- "$config_tmp" "$config_path"',
      'mv -f -- "$token_tmp" "$token_path"',
      'trap - 0 1 2 15',
      `unset ${CODEX_RUNTIME_CONFIG_TOML_ENV} ${CODEX_RUNTIME_TOKEN_ENV}`
    )
  }

  if (deleteLogs) {
    const databaseArgs = CODEX_LOGS2_DATABASE_NAMES.map((_, index) => `"$${index + 1}"`).join(' ')
    statements.push(`rm -f -- ${databaseArgs}; shift ${CODEX_LOGS2_DATABASE_NAMES.length}`)
  }
  statements.push('exec "$@"')
  return statements.join('; ')
}

function flockCommand(): string {
  return process.env.ANKOLE_FLOCK_BINARY || 'flock'
}
