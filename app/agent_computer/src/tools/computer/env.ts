export type CommandEnvOptions = {
  home?: string
  ankoleAgentHome?: string
  /** Operator-managed variables resolved from the control plane for this turn's agent. */
  workerEnv?: Record<string, string>
}

const ENV_NAME_FORMAT = /^[A-Za-z_][A-Za-z0-9_]*$/

// Defense-in-depth mirror of the control-plane reserved list: these names
// belong to the sandbox bootstrap or worker identity, and an operator row
// must not displace them even if a stale control plane lets one through.
const RESERVED_WORKER_ENV_NAMES = new Set([
  'PATH',
  'HOME',
  'SHELL',
  'TERM',
  'LANG',
  'BASH_ENV',
  'ENV',
  'WORKER_ID',
  'RUNTIME_FABRIC_URL',
  'DATABASE_URL',
  'CODEX_UNSAFE_ALLOW_NO_SANDBOX'
])
const RESERVED_WORKER_ENV_PREFIX = 'ANKOLE_'

/**
 * Filters an operator env map down to injectable entries.
 *
 * Kept as a separate filter so tests and every shell-environment caller apply
 * the same reserved-name policy.
 */
export function injectableWorkerEnv(workerEnv: Record<string, string> | undefined): Array<[string, string]> {
  return Object.entries(workerEnv ?? {}).filter(
    ([key, value]) =>
      typeof value === 'string' &&
      ENV_NAME_FORMAT.test(key) &&
      !RESERVED_WORKER_ENV_NAMES.has(key) &&
      !key.startsWith(RESERVED_WORKER_ENV_PREFIX)
  )
}

/**
 * Builds the allowlisted command environment passed into sandboxed commands.
 *
 * Layering, low to high: fixed sandbox base, operator worker env, then the
 * caller's per-command env. The model's explicit `env` wins for one command
 * (plain shell semantics — it could `export` past any ordering anyway).
 */
export function commandEnv(
  inputEnv: Record<string, string> | undefined,
  options: CommandEnvOptions = {}
): Record<string, string> {
  const shellBootstrap = process.env.BASH_ENV ?? inputEnv?.BASH_ENV ?? '/etc/profile.d/ankole-agent-computer.sh'
  const env: Record<string, string> = {
    PATH: commandPath(process.env.PATH),
    HOME: options.home ?? process.env.HOME ?? '/agents',
    LANG: process.env.LANG ?? 'C.UTF-8',
    TERM: process.env.TERM ?? 'xterm-256color',
    SHELL: process.env.SHELL ?? '/bin/bash',
    BASH_ENV: shellBootstrap,
    ENV: process.env.ENV ?? inputEnv?.ENV ?? shellBootstrap,
    CODEX_UNSAFE_ALLOW_NO_SANDBOX: process.env.CODEX_UNSAFE_ALLOW_NO_SANDBOX ?? '1',
    ANKOLE_AGENT_HOME: options.ankoleAgentHome ?? options.home ?? process.env.ANKOLE_AGENT_HOME ?? '/agents'
  }

  for (const [key, value] of injectableWorkerEnv(options.workerEnv)) {
    env[key] = value
  }

  for (const [key, value] of Object.entries(inputEnv ?? {})) {
    if (ENV_NAME_FORMAT.test(key)) env[key] = value
  }

  if (options.home !== undefined) env.HOME = options.home
  if (options.ankoleAgentHome !== undefined) env.ANKOLE_AGENT_HOME = options.ankoleAgentHome

  return env
}

/**
 * Ensures core command directories appear at the front of PATH.
 */
function commandPath(path: string | undefined): string {
  const required = ['/usr/local/bin', '/usr/bin', '/bin']
  const current = path?.split(':').filter(Boolean) ?? []
  return [...required, ...current.filter(entry => !required.includes(entry))].join(':')
}
