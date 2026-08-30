export type CommandEnvOptions = {
  home?: string
  ankoleAgentHome?: string
  /** Operator-managed variables resolved for this execution's Agent. */
  workerEnv?: Record<string, string>
  /** Trusted execution-scoped variables supplied by the Worker. */
  runtimeEnv?: Record<string, string>
}

/** Portable shell variable-name boundary for all injected values. */
const ENV_NAME_FORMAT = /^[A-Za-z_][A-Za-z0-9_]*$/

// This defense-in-depth list mirrors the control-plane policy. Operator values
// cannot replace sandbox bootstrap or Worker identity.
const RESERVED_WORKER_ENV_NAMES = new Set([
  'PATH',
  'HOME',
  'SHELL',
  'TERM',
  'LANG',
  'BASH_ENV',
  'ENV',
  'WORKER_ID',
  'DATABASE_URL',
  'CODEX_UNSAFE_ALLOW_NO_SANDBOX'
])
/** Prefix that reserves all Ankole bootstrap and runtime values. */
const RESERVED_WORKER_ENV_PREFIX = 'ANKOLE_'
/** Prefix allowed only in the trusted execution runtime layer. */
const RUNTIME_ENV_PREFIX = 'ANKOLE_RUNTIME_'

/**
 * Operator values cannot replace sandbox bootstrap, Worker identity, or
 * Ankole-owned runtime values.
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
 * Builds the complete environment passed into sandboxed commands.
 *
 * Layering, low to high: fixed sandbox base, operator WorkerEnv, caller
 * variables, then trusted execution runtime values.
 */
export function commandEnv(
  inputEnv: Record<string, string> | undefined,
  options: CommandEnvOptions = {}
): Record<string, string> {
  const shellBootstrap = process.env.BASH_ENV ?? inputEnv?.BASH_ENV ?? '/etc/profile.d/ankole-agent-computer.sh'

  for (const [key, value] of Object.entries(options.runtimeEnv ?? {})) {
    if (
      !ENV_NAME_FORMAT.test(key) ||
      !key.startsWith(RUNTIME_ENV_PREFIX) ||
      typeof value !== 'string' ||
      value.includes('\0')
    ) {
      throw new Error(`invalid turn runtime environment variable: ${key}`)
    }
  }

  return {
    // Fixed sandbox base.
    PATH: commandPath(process.env.PATH),
    HOME: process.env.HOME ?? '/agents',
    LANG: process.env.LANG ?? 'C.UTF-8',
    TERM: process.env.TERM ?? 'xterm-256color',
    SHELL: process.env.SHELL ?? '/bin/bash',
    BASH_ENV: shellBootstrap,
    ENV: process.env.ENV ?? inputEnv?.ENV ?? shellBootstrap,
    CODEX_UNSAFE_ALLOW_NO_SANDBOX: process.env.CODEX_UNSAFE_ALLOW_NO_SANDBOX ?? '1',
    ANKOLE_AGENT_HOME: options.home ?? process.env.ANKOLE_AGENT_HOME ?? '/agents',
    // Operator WorkerEnv, then caller variables.
    ...Object.fromEntries(injectableWorkerEnv(options.workerEnv)),
    ...Object.fromEntries(Object.entries(inputEnv ?? {}).filter(([key]) => ENV_NAME_FORMAT.test(key))),
    // Trusted execution runtime values win over every lower layer.
    ...options.runtimeEnv,
    ...(options.home !== undefined ? { HOME: options.home } : {}),
    ...(options.ankoleAgentHome !== undefined ? { ANKOLE_AGENT_HOME: options.ankoleAgentHome } : {})
  }
}

// Image-provided wrappers must win over entries inherited from the Worker process.
function commandPath(path: string | undefined): string {
  const required = ['/usr/local/bin', '/usr/bin', '/bin']
  const current = path?.split(':').filter(Boolean) ?? []
  return [...required, ...current.filter(entry => !required.includes(entry))].join(':')
}
