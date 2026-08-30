import { existsSync } from 'node:fs'
import { dirname, resolve } from 'node:path'
import { bubblewrapArgv } from '../../../sandbox/bubblewrap'
import { commandEnv } from '../../../sandbox/command-env'
import { codexConfigCLIOverrides, type MaterializedCodexConfig } from './agent-home-config'

/**
 * The app-server process receives only Agent-scoped environment.
 * Each Job receives Worker, binding, and Browser values through its thread
 * configuration.
 */
export type CodexAppServerSandboxSpec = {
  cwd: string
  env: Record<string, string>
  commandArgv: string[]
  codexCwd: string
}

/** Fixed read-only path for the image-owned native kernel. */
const SANDBOX_KERNEL_ROOT = '/repo/app/kernel'

export function codexAgentRuntimeSandboxSpec(input: {
  materialized: MaterializedCodexConfig
  browserRuntime?: { root: string; socketPath: string }
}): CodexAppServerSandboxSpec {
  const env = codexSandboxEnv(input.materialized)
  const appServerArgv = bubblewrapArgv({
    workspaceRoot: input.materialized.agentHome,
    cwd: input.materialized.agentHome,
    env,
    extraBinds: [
      {
        source: input.materialized.codexHome,
        target: input.materialized.codexHome
      },
      ...(existsSync(SANDBOX_KERNEL_ROOT)
        ? [{ source: SANDBOX_KERNEL_ROOT, target: SANDBOX_KERNEL_ROOT, readonly: true }]
        : []),
      ...(input.browserRuntime
        ? [
            { source: input.browserRuntime.root, target: input.browserRuntime.root, readonly: true },
            {
              source: dirname(input.browserRuntime.socketPath),
              target: dirname(input.browserRuntime.socketPath),
              readonly: true
            }
          ]
        : [])
    ],
    commandArgv: [...codexCommandForSandbox(), 'app-server', '--stdio', ...codexConfigCLIOverrides()]
  })
  return {
    cwd: input.materialized.agentHome,
    env,
    codexCwd: input.materialized.agentHome,
    commandArgv: appServerArgv
  }
}

export function codexJobThreadEnv(input: {
  materialized: MaterializedCodexConfig
  workerEnv?: Record<string, string>
  runtimeEnv?: Record<string, string>
  browserEnv?: Record<string, string>
}): Record<string, string> {
  return codexSandboxEnv(input.materialized, input.workerEnv, input.runtimeEnv, input.browserEnv)
}

function codexSandboxEnv(
  materialized: MaterializedCodexConfig,
  workerEnv?: Record<string, string>,
  runtimeEnv?: Record<string, string>,
  browserEnv?: Record<string, string>
): Record<string, string> {
  const next = commandEnv(materialized.env, {
    home: materialized.agentHome,
    ankoleAgentHome: materialized.agentHome,
    workerEnv,
    runtimeEnv
  })
  next.ANKOLE_KERNEL_ROOT = SANDBOX_KERNEL_ROOT
  Object.assign(next, browserEnv)
  return next
}

function codexCommandForSandbox(): string[] {
  const binary = process.env.ANKOLE_CODEX_BINARY
  if (!binary) return ['codex']
  if (!binary.startsWith('/')) return [binary]
  return [resolve(binary)]
}
