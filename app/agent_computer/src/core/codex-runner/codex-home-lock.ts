import { join } from 'node:path'

export const CODEX_HOME_LOCK_BUSY_EXIT_CODE = 75
export const CODEX_HOME_RUNTIME_LOCK_NAME = '.ankole-app-server.lock'
export const CODEX_RUNTIME_CONFIG_TOML_ENV = 'ANKOLE_CODEX_RUNTIME_CONFIG_TOML'
export const CODEX_RUNTIME_TOKEN_ENV = 'ANKOLE_CODEX_RUNTIME_TOKEN'
export const CODEX_LOGS2_DATABASE_NAMES = [
  'logs_2.sqlite',
  'logs_2.sqlite-wal',
  'logs_2.sqlite-shm',
  'logs_2.sqlite-journal'
] as const

export function codexHomeRuntimeLockPath(codexHome: string): string {
  return join(codexHome, CODEX_HOME_RUNTIME_LOCK_NAME)
}

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
