export type CommandEnvOptions = {
  /** Agent Home of the execution. The command gets it as HOME and ANKOLE_AGENT_HOME. */
  agentHome: string
  /** Operator-managed variables resolved for this execution's Agent. */
  workerEnv?: Record<string, string>
  /** Trusted execution-scoped variables supplied by the Worker. */
  runtimeEnv?: Record<string, string>
}

/** The control plane checks names at storage and binding resolution. */
const ENV_NAME_FORMAT = /^[A-Za-z_][A-Za-z0-9_]*$/

/**
 * Builds the complete environment of a command. The command does not inherit
 * the Worker environment. UID separation also protects the credential in
 * the Worker and supervisor process environments.
 *
 * Layering, low to high: fixed base, operator WorkerEnv, caller variables,
 * trusted execution runtime values, then the Agent Home.
 */
export function commandEnv(
  inputEnv: Record<string, string> | undefined,
  options: CommandEnvOptions
): Record<string, string> {
  return {
    // The Worker image sets these values, and the entry restores them.
    PATH: commandPath(process.env.PATH),
    LANG: process.env.LANG ?? 'C.UTF-8',
    TERM: process.env.TERM ?? 'xterm-256color',
    SHELL: process.env.SHELL!,
    BASH_ENV: process.env.BASH_ENV!,
    ENV: process.env.ENV!,
    CODEX_UNSAFE_ALLOW_NO_SANDBOX: process.env.CODEX_UNSAFE_ALLOW_NO_SANDBOX!,
    // Operator WorkerEnv, then caller variables.
    ...options.workerEnv,
    ...Object.fromEntries(Object.entries(inputEnv ?? {}).filter(([key]) => ENV_NAME_FORMAT.test(key))),
    // Trusted execution runtime values win over every lower layer.
    ...options.runtimeEnv,
    // No layer can change the Agent Home.
    HOME: options.agentHome,
    ANKOLE_AGENT_HOME: options.agentHome
  }
}

// Image-provided wrappers must win over entries inherited from the Worker process.
function commandPath(path: string | undefined): string {
  const required = ['/usr/local/bin', '/usr/bin', '/bin']
  const current = path?.split(':').filter(Boolean) ?? []
  return [...required, ...current.filter(entry => !required.includes(entry))].join(':')
}
