import { WORKSPACE_MODEL_ROOT } from '../../core/workspace-paths'

export type CommandEnvOptions = {
  home?: string
  ankoleWorkspaceRoot?: string
}

/**
 * Builds the allowlisted command environment passed into sandboxed commands.
 */
export function commandEnv(
  inputEnv: Record<string, string> | undefined,
  options: CommandEnvOptions = {}
): Record<string, string> {
  const shellBootstrap = process.env.BASH_ENV ?? inputEnv?.BASH_ENV ?? '/etc/profile.d/ankole-agent-computer.sh'
  const env: Record<string, string> = {
    PATH: commandPath(process.env.PATH),
    HOME: process.env.HOME ?? WORKSPACE_MODEL_ROOT,
    LANG: process.env.LANG ?? 'C.UTF-8',
    TERM: process.env.TERM ?? 'xterm-256color',
    SHELL: process.env.SHELL ?? '/bin/bash',
    BASH_ENV: shellBootstrap,
    ENV: process.env.ENV ?? inputEnv?.ENV ?? shellBootstrap,
    CODEX_UNSAFE_ALLOW_NO_SANDBOX: process.env.CODEX_UNSAFE_ALLOW_NO_SANDBOX ?? '1',
    ANKOLE_WORKSPACE_ROOT: process.env.ANKOLE_WORKSPACE_ROOT ?? WORKSPACE_MODEL_ROOT
  }

  for (const [key, value] of Object.entries(inputEnv ?? {})) {
    if (/^[A-Za-z_][A-Za-z0-9_]*$/.test(key)) env[key] = value
  }

  if (options.home !== undefined) env.HOME = options.home
  if (options.ankoleWorkspaceRoot !== undefined) env.ANKOLE_WORKSPACE_ROOT = options.ankoleWorkspaceRoot

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
